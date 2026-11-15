package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const userAgent = "MameLLM/" + version

var httpClient = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 20 * time.Second}).DialContext,
	TLSHandshakeTimeout:   20 * time.Second,
	ResponseHeaderTimeout: 40 * time.Second,
	MaxIdleConns:          8,
	IdleConnTimeout:       60 * time.Second,
}}

// Job is one download (a model or the runtime) shown in the UI.
type Job struct {
	ID      string   `json:"id"`
	ModelID string   `json:"model_id,omitempty"`
	Name    string   `json:"name"`
	Status  string   `json:"status"` // running | verifying | done | error | canceled
	Source  string   `json:"source"`
	Error   string   `json:"error,omitempty"`
	Bytes   int64    `json:"bytes"`
	Total   int64    `json:"total"`
	Speed   float64  `json:"speed"`
	Log     []string `json:"log"`

	cancel context.CancelFunc
}

type Downloader struct {
	store *Store
	mu    sync.Mutex
	jobs  []*Job
	seq   int
}

func (d *Downloader) Snapshot() []Job {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]Job, len(d.jobs))
	for i, j := range d.jobs {
		out[i] = *j
		out[i].Log = append([]string{}, j.Log...)
	}
	return out
}

func (d *Downloader) update(j *Job, f func(*Job)) {
	d.mu.Lock()
	f(j)
	d.mu.Unlock()
}

func (d *Downloader) logf(j *Job, format string, a ...any) {
	d.update(j, func(j *Job) {
		j.Log = append(j.Log, fmt.Sprintf(format, a...))
		if len(j.Log) > 30 {
			j.Log = j.Log[len(j.Log)-30:]
		}
	})
}

// newJob registers a job unless an active one already exists for key.
func (d *Downloader) newJob(key, name string) (*Job, context.Context, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, j := range d.jobs {
		if j.ModelID == key && (j.Status == "running" || j.Status == "verifying") {
			return j, nil, false
		}
	}
	// drop finished jobs for the same key so the list stays short
	kept := d.jobs[:0]
	for _, j := range d.jobs {
		if j.ModelID != key {
			kept = append(kept, j)
		}
	}
	d.jobs = kept
	d.seq++
	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{ID: fmt.Sprintf("job-%d", d.seq), ModelID: key, Name: name, Status: "running", cancel: cancel}
	d.jobs = append(d.jobs, j)
	return j, ctx, true
}

func (d *Downloader) finish(j *Job, err error) {
	d.update(j, func(j *Job) {
		j.Speed = 0
		switch {
		case err == nil:
			j.Status = "done"
		case errors.Is(err, context.Canceled):
			j.Status, j.Error = "canceled", ""
		default:
			j.Status, j.Error = "error", err.Error()
		}
	})
	j.cancel()
}

func (d *Downloader) Cancel(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, j := range d.jobs {
		if j.ID == id && (j.Status == "running" || j.Status == "verifying") {
			j.cancel()
		}
	}
}

func (d *Downloader) Dismiss(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	kept := d.jobs[:0]
	for _, j := range d.jobs {
		if j.ID != id || j.Status == "running" || j.Status == "verifying" {
			kept = append(kept, j)
		}
	}
	d.jobs = kept
}

// target is one concrete place to fetch a file from.
type target struct {
	src     Source
	url     string
	header  http.Header
	sha256  string
	size    int64
	resolve func(ctx context.Context, t *target) error // fills url/sha256/size lazily
}

func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}

// modelTargets lists every place the model can come from, in priority order.
// If only is set, just that source is used (even when disabled).
func (d *Downloader) modelTargets(m Model, only string) []*target {
	var out []*target
	token := d.store.Settings().HFToken
	for _, src := range d.store.Sources() {
		if src.Runtime || (only == "" && !src.Enabled) || (only != "" && src.ID != only) {
			continue
		}
		for _, r := range m.Refs {
			t := &target{src: src, sha256: r.SHA256, size: r.Size, header: http.Header{}}
			switch {
			case src.Kind == "hf" && r.Kind == "hf":
				t.url = src.Base + "/" + escapePath(r.Repo) + "/resolve/main/" + escapePath(r.File)
				if token != "" && src.ID == "huggingface" {
					t.header.Set("Authorization", "Bearer "+token)
				}
			case src.Kind == "modelscope" && r.Kind == "hf" && !r.NoModelScope:
				t.url = src.Base + "/models/" + escapePath(r.Repo) + "/resolve/master/" + escapePath(r.File)
			case src.Kind == "template" && r.Kind == "hf":
				t.url = strings.NewReplacer("{repo}", escapePath(r.Repo), "{file}", escapePath(r.File)).Replace(src.Base)
			case src.Kind == "ollama" && r.Kind == "ollama":
				ref := r.Ref
				t.sha256, t.size = "", 0
				t.resolve = func(ctx context.Context, t *target) error { return resolveOllama(ctx, t, ref) }
			case src.Kind == "url" && r.Kind == "url":
				t.url = r.URL
			default:
				continue
			}
			out = append(out, t)
		}
	}
	return out
}

func parseOllamaRef(ref string) (ns, name, tag string, err error) {
	ref = strings.TrimPrefix(strings.TrimSpace(ref), "ollama.com/")
	name, tag, _ = strings.Cut(ref, ":")
	if tag == "" {
		tag = "latest"
	}
	ns = "library"
	if a, b, ok := strings.Cut(name, "/"); ok {
		ns, name = a, b
	}
	for _, s := range []string{ns, name, tag} {
		if s == "" || strings.ContainsAny(s, "/\\ ?#") || strings.Contains(s, "..") {
			return "", "", "", fmt.Errorf("Ollamaのモデル名が不正です: %q (例: gemma3:1b)", ref)
		}
	}
	return ns, name, tag, nil
}

// resolveOllama reads the registry manifest and points the target at the
// GGUF blob layer.
func resolveOllama(ctx context.Context, t *target, ref string) error {
	ns, name, tag, err := parseOllamaRef(ref)
	if err != nil {
		return err
	}
	repo := t.src.Base + "/v2/" + url.PathEscape(ns) + "/" + url.PathEscape(name)
	req, _ := http.NewRequestWithContext(ctx, "GET", repo+"/manifests/"+url.PathEscape(tag), nil)
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	req.Header.Set("User-Agent", userAgent)
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("マニフェスト取得失敗: HTTP %d", resp.StatusCode)
	}
	var man struct {
		Layers []struct {
			MediaType string `json:"mediaType"`
			Digest    string `json:"digest"`
			Size      int64  `json:"size"`
		} `json:"layers"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&man); err != nil {
		return fmt.Errorf("マニフェスト解析失敗: %w", err)
	}
	for _, l := range man.Layers {
		if l.MediaType == "application/vnd.ollama.image.model" && strings.HasPrefix(l.Digest, "sha256:") {
			t.url = repo + "/blobs/" + l.Digest
			t.sha256 = strings.TrimPrefix(l.Digest, "sha256:")
			t.size = l.Size
			return nil
		}
	}
	return errors.New("マニフェストにモデル本体(GGUF)がありません")
}

// StartModel begins downloading a model, trying each source in turn.
func (d *Downloader) StartModel(m Model, only string) (*Job, error) {
	if m.LocalPath != "" {
		return nil, errors.New("ローカル登録のモデルはダウンロード不要です")
	}
	targets := d.modelTargets(m, only)
	if len(targets) == 0 {
		return nil, errors.New("このモデルを取得できる有効なダウンロード元がありません。「ダウンロード元」タブで有効化するか追加してください")
	}
	j, ctx, fresh := d.newJob(m.ID, m.Name)
	if !fresh {
		return j, nil
	}
	d.update(j, func(j *Job) { j.Total = m.Size })
	go func() {
		dest := d.store.ModelPath(m)
		err := d.tryTargets(ctx, j, targets, dest, true)
		d.finish(j, err)
	}()
	return j, nil
}

func (d *Downloader) tryTargets(ctx context.Context, j *Job, targets []*target, dest string, gguf bool) error {
	var last error
	for i, t := range targets {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		d.update(j, func(j *Job) { j.Source, j.Speed = t.src.Name, 0 })
		if t.resolve != nil {
			if err := t.resolve(ctx, t); err != nil {
				last = err
				d.logf(j, "✗ %s: %v", t.src.Name, err)
				continue
			}
		}
		d.logf(j, "→ %s から取得中 (%d/%d)", t.src.Name, i+1, len(targets))
		err := d.fetch(ctx, j, t, dest, gguf)
		if err == nil {
			d.logf(j, "✓ %s から取得完了", t.src.Name)
			return nil
		}
		if errors.Is(err, context.Canceled) && ctx.Err() != nil {
			return context.Canceled
		}
		last = err
		d.logf(j, "✗ %s: %v", t.src.Name, err)
	}
	return fmt.Errorf("すべてのダウンロード元で失敗しました(最後のエラー: %v)", last)
}

type partMeta struct {
	Key string `json:"key"`
}

// fetch downloads t to dest with resume, stall detection and verification.
func (d *Downloader) fetch(parent context.Context, j *Job, t *target, dest string, gguf bool) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	part, metaPath := dest+".part", dest+".part.json"
	key := t.sha256
	if key == "" {
		key = t.url
	}
	var offset int64
	if b, err := os.ReadFile(metaPath); err == nil {
		var pm partMeta
		if json.Unmarshal(b, &pm) == nil && pm.Key == key {
			if st, err := os.Stat(part); err == nil {
				offset = st.Size()
			}
		}
	}
	if offset == 0 {
		os.Remove(part)
	}
	if t.size > 0 && offset > t.size {
		offset = 0
		os.Remove(part)
	}

	if !(t.size > 0 && offset == t.size) { // otherwise the part is already complete
		req, _ := http.NewRequestWithContext(ctx, "GET", t.url, nil)
		for k, v := range t.header {
			req.Header[k] = v
		}
		req.Header.Set("User-Agent", userAgent)
		if offset > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
		}
		resp, err := httpClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		switch resp.StatusCode {
		case 200:
			offset = 0
		case 206:
		case 416:
			os.Remove(part)
			os.Remove(metaPath)
			return errors.New("再開位置が不正でした(次回は最初から取得します)")
		case 401, 403:
			return fmt.Errorf("HTTP %d(アクセス権が必要なモデルの可能性。設定でHFトークンを指定できます)", resp.StatusCode)
		default:
			return fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		if ct := resp.Header.Get("Content-Type"); strings.HasPrefix(ct, "text/html") {
			return errors.New("ファイルではなくHTMLページが返されました")
		}
		total := t.size
		if total == 0 && resp.ContentLength > 0 {
			total = offset + resp.ContentLength
		}
		if t.size > 0 && resp.ContentLength > 0 && offset+resp.ContentLength != t.size {
			return fmt.Errorf("サイズが想定と異なります(想定 %d / 実際 %d)", t.size, offset+resp.ContentLength)
		}
		flags := os.O_CREATE | os.O_WRONLY
		if offset > 0 {
			flags |= os.O_APPEND
		} else {
			flags |= os.O_TRUNC
		}
		f, err := os.OpenFile(part, flags, 0o644)
		if err != nil {
			return err
		}
		meta, _ := json.Marshal(partMeta{Key: key})
		os.WriteFile(metaPath, meta, 0o644)
		d.update(j, func(j *Job) { j.Bytes, j.Total, j.Status = offset, total, "running" })

		// stall watchdog + speed meter
		var got atomic.Int64
		got.Store(offset)
		done := make(chan struct{})
		var stalled atomic.Bool
		go func() {
			tick := time.NewTicker(time.Second)
			defer tick.Stop()
			prev, idle := offset, 0
			for {
				select {
				case <-done:
					return
				case <-tick.C:
					cur := got.Load()
					if cur == prev {
						if idle++; idle >= 60 {
							stalled.Store(true)
							cancel()
							return
						}
					} else {
						idle = 0
					}
					sp := float64(cur - prev)
					prev = cur
					d.update(j, func(j *Job) { j.Bytes, j.Speed = cur, 0.6*j.Speed+0.4*sp })
				}
			}
		}()
		buf := make([]byte, 256<<10)
		var copyErr error
		for {
			n, rerr := resp.Body.Read(buf)
			if n > 0 {
				if _, werr := f.Write(buf[:n]); werr != nil {
					copyErr = werr
					break
				}
				got.Add(int64(n))
			}
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				copyErr = rerr
				break
			}
		}
		close(done)
		cerr := f.Close()
		d.update(j, func(j *Job) { j.Bytes, j.Speed = got.Load(), 0 })
		if stalled.Load() {
			return errors.New("60秒間データが届かないため中断しました(続きから再開できます)")
		}
		if copyErr != nil {
			if parent.Err() != nil {
				return context.Canceled
			}
			return copyErr
		}
		if cerr != nil {
			return cerr
		}
		if total > 0 && got.Load() != total {
			return fmt.Errorf("途中で切断されました(%d / %d バイト。続きから再開できます)", got.Load(), total)
		}
	}

	// verification; a bad file is discarded so the next source starts clean
	bad := func(err error) error {
		os.Remove(part)
		os.Remove(metaPath)
		return err
	}
	if gguf {
		f, err := os.Open(part)
		if err != nil {
			return err
		}
		magic := make([]byte, 4)
		_, err = io.ReadFull(f, magic)
		f.Close()
		if err != nil || string(magic) != "GGUF" {
			return bad(errors.New("GGUF形式のファイルではありません"))
		}
	}
	if t.sha256 != "" {
		d.update(j, func(j *Job) { j.Status = "verifying" })
		sum, err := fileSHA256(parent, part)
		if err != nil {
			return err
		}
		if !strings.EqualFold(sum, t.sha256) {
			return bad(errors.New("SHA-256が一致しません(破損または改変の可能性があるため破棄しました)"))
		}
	}
	os.Remove(metaPath)
	return os.Rename(part, dest)
}

func fileSHA256(ctx context.Context, path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	buf := make([]byte, 1<<20)
	for {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		n, err := f.Read(buf)
		h.Write(buf[:n])
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// DeleteModelFiles removes a downloaded model and any partial download.
func (d *Downloader) DeleteModelFiles(m Model) error {
	if m.LocalPath != "" {
		return nil // registered in place: never delete the user's own file
	}
	p := d.store.ModelPath(m)
	os.Remove(p + ".part")
	os.Remove(p + ".part.json")
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
