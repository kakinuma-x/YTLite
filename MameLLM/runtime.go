package main

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const llamaRepo = "ggml-org/llama.cpp"

func serverBinName() string {
	if runtime.GOOS == "windows" {
		return "llama-server.exe"
	}
	return "llama-server"
}

// runtimeAsset is the platform part of llama.cpp's release file names.
func runtimeAsset() (string, error) {
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/arm64":
		return "macos-arm64", nil
	case "darwin/amd64":
		return "macos-x64", nil
	case "linux/amd64":
		return "ubuntu-x64", nil
	case "linux/arm64":
		return "ubuntu-arm64", nil
	}
	return "", fmt.Errorf("この環境(%s/%s)向けのllama.cpp公式ビルドはありません", runtime.GOOS, runtime.GOARCH)
}

type RuntimeInfo struct {
	Path    string `json:"path"`
	Origin  string `json:"origin"` // settings | managed | system
	Version string `json:"version,omitempty"`
}

// FindRuntime locates llama-server: explicit setting, then our own download,
// then one already installed on the system (e.g. Homebrew).
func (s *Store) FindRuntime() (RuntimeInfo, bool) {
	if p := s.Settings().RuntimePath; p != "" {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			return RuntimeInfo{Path: p, Origin: "settings"}, true
		}
	}
	entries, _ := os.ReadDir(s.RuntimeDir())
	var tags []string
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			tags = append(tags, e.Name())
		}
	}
	// newest first: llama.cpp tags are "b<build number>"
	sort.Slice(tags, func(i, j int) bool {
		a, _ := strconv.Atoi(strings.TrimPrefix(tags[i], "b"))
		b, _ := strconv.Atoi(strings.TrimPrefix(tags[j], "b"))
		if a != b {
			return a > b
		}
		return tags[i] > tags[j]
	})
	for _, tag := range tags {
		var found string
		filepath.WalkDir(filepath.Join(s.RuntimeDir(), tag), func(p string, de os.DirEntry, err error) error {
			if err == nil && found == "" && !de.IsDir() && de.Name() == serverBinName() {
				found = p
			}
			return nil
		})
		if found != "" {
			return RuntimeInfo{Path: found, Origin: "managed", Version: tag}, true
		}
	}
	if p, err := exec.LookPath(serverBinName()); err == nil {
		return RuntimeInfo{Path: p, Origin: "system"}, true
	}
	for _, p := range []string{"/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"} {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			return RuntimeInfo{Path: p, Origin: "system"}, true
		}
	}
	return RuntimeInfo{}, false
}

func githubURL(src Source, path string) string {
	if src.Kind == "github-mirror" {
		return src.Base + "https://github.com" + path
	}
	return strings.TrimRight(src.Base, "/") + path
}

var tagRe = regexp.MustCompile(`/releases/tag/([A-Za-z0-9._-]+)`)

// latestTag finds the newest llama.cpp release without the rate-limited API:
// /releases/latest redirects to /releases/tag/<tag>.
func latestTag(ctx context.Context, src Source) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", githubURL(src, "/"+llamaRepo+"/releases/latest"), nil)
	req.Header.Set("User-Agent", userAgent)
	c := *httpClient
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if m := tagRe.FindStringSubmatch(resp.Header.Get("Location")); m != nil {
		return m[1], nil
	}
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("最新版の確認に失敗: HTTP %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if m := tagRe.FindSubmatch(body); m != nil {
		return string(m[1]), nil
	}
	return "", errors.New("最新版のタグが見つかりません")
}

// StartRuntime downloads and unpacks the llama.cpp runtime.
func (d *Downloader) StartRuntime(only string) (*Job, error) {
	plat, err := runtimeAsset()
	if err != nil {
		return nil, err
	}
	var srcs []Source
	for _, src := range d.store.Sources() {
		if src.Runtime && ((only == "" && src.Enabled) || src.ID == only) {
			srcs = append(srcs, src)
		}
	}
	if len(srcs) == 0 {
		return nil, errors.New("有効なランタイム配布元がありません")
	}
	j, ctx, fresh := d.newJob("@runtime", "llama.cpp ランタイム")
	if !fresh {
		return j, nil
	}
	go func() { d.finish(j, d.installRuntime(ctx, j, srcs, plat)) }()
	return j, nil
}

func (d *Downloader) installRuntime(ctx context.Context, j *Job, srcs []Source, plat string) error {
	var last error
	for _, src := range srcs {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		d.update(j, func(j *Job) { j.Source = src.Name })
		tag, err := latestTag(ctx, src)
		if err != nil {
			last = err
			d.logf(j, "✗ %s: %v", src.Name, err)
			continue
		}
		d.logf(j, "最新版: %s", tag)
		for _, ext := range []string{".tar.gz", ".zip"} {
			name := fmt.Sprintf("llama-%s-bin-%s%s", tag, plat, ext)
			t := &target{src: src, header: http.Header{},
				url: githubURL(src, fmt.Sprintf("/%s/releases/download/%s/%s", llamaRepo, tag, name))}
			archive := filepath.Join(d.store.RuntimeDir(), "."+name)
			if err = d.tryTargets(ctx, j, []*target{t}, archive, false); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				continue
			}
			dest := filepath.Join(d.store.RuntimeDir(), tag)
			tmp := dest + ".tmp"
			os.RemoveAll(tmp)
			if ext == ".zip" {
				err = unzip(archive, tmp)
			} else {
				err = untar(archive, tmp)
			}
			os.Remove(archive)
			if err == nil {
				os.RemoveAll(dest)
				err = os.Rename(tmp, dest)
			}
			if err != nil {
				os.RemoveAll(tmp)
				d.logf(j, "✗ 展開に失敗: %v", err)
				continue
			}
			if !hasServerBin(dest) {
				os.RemoveAll(dest)
				err = errors.New("展開したアーカイブに llama-server がありません")
				d.logf(j, "✗ %v", err)
				continue
			}
			d.logf(j, "✓ %s をインストールしました", tag)
			return nil
		}
		last = err
	}
	return fmt.Errorf("ランタイムを取得できませんでした(最後のエラー: %v)。Homebrewがあれば「brew install llama.cpp」でも導入できます", last)
}

func hasServerBin(dir string) bool {
	found := false
	filepath.WalkDir(dir, func(p string, de os.DirEntry, err error) error {
		if err == nil && !de.IsDir() && de.Name() == serverBinName() {
			found = true
		}
		return nil
	})
	return found
}

// inside reports whether p stays under root after cleaning.
func inside(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func untar(archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		p := filepath.Join(dest, filepath.FromSlash(h.Name))
		if !inside(dest, p) {
			return fmt.Errorf("不正なパス: %s", h.Name)
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeFile(p, tr, os.FileMode(h.Mode)&0o777); err != nil {
				return err
			}
		case tar.TypeSymlink:
			// only links that stay inside the archive (versioned dylibs)
			if filepath.IsAbs(h.Linkname) || !inside(dest, filepath.Join(filepath.Dir(p), filepath.FromSlash(h.Linkname))) {
				return fmt.Errorf("不正なリンク: %s", h.Name)
			}
			os.MkdirAll(filepath.Dir(p), 0o755)
			os.Remove(p)
			if err := os.Symlink(h.Linkname, p); err != nil {
				return err
			}
		}
	}
}

func unzip(archive, dest string) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, zf := range zr.File {
		p := filepath.Join(dest, filepath.FromSlash(zf.Name))
		if !inside(dest, p) {
			return fmt.Errorf("不正なパス: %s", zf.Name)
		}
		if zf.FileInfo().IsDir() {
			os.MkdirAll(p, 0o755)
			continue
		}
		if zf.Mode()&os.ModeSymlink != 0 {
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			return err
		}
		mode := zf.Mode() & 0o777
		if filepath.Base(p) == serverBinName() {
			mode |= 0o755
		}
		err = writeFile(p, rc, mode)
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func writeFile(p string, r io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if mode == 0 {
		mode = 0o644
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// ---- llama-server process ----

type ringLog struct {
	mu    sync.Mutex
	lines []string
	cur   []byte
}

func (r *ringLog) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, b := range p {
		if b == '\n' {
			r.lines = append(r.lines, string(r.cur))
			r.cur = r.cur[:0]
			if len(r.lines) > 200 {
				r.lines = r.lines[len(r.lines)-200:]
			}
		} else if len(r.cur) < 2000 {
			r.cur = append(r.cur, b)
		}
	}
	return len(p), nil
}

func (r *ringLog) Tail(n int) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.lines) < n {
		n = len(r.lines)
	}
	return append([]string{}, r.lines[len(r.lines)-n:]...)
}

type EngineState struct {
	Status  string   `json:"status"` // stopped | loading | ready | error
	ModelID string   `json:"model_id"`
	Error   string   `json:"error,omitempty"`
	Context int      `json:"context"`
	Log     []string `json:"log,omitempty"`
}

// Engine owns the single llama-server process. Only one model is ever
// loaded, and it is unloaded when idle so memory returns to the system.
type Engine struct {
	store  *Store
	loadMu sync.Mutex // serialises Load/Stop

	mu       sync.Mutex
	st       EngineState
	cmd      *exec.Cmd
	exited   chan struct{}
	port     int
	log      *ringLog
	lastUsed time.Time
	active   int
}

func newEngine(s *Store) *Engine {
	e := &Engine{store: s, st: EngineState{Status: "stopped"}, log: &ringLog{}}
	go e.idleLoop()
	return e
}

func (e *Engine) State() EngineState {
	e.mu.Lock()
	defer e.mu.Unlock()
	st := e.st
	if st.Status == "error" || st.Status == "loading" {
		st.Log = e.log.Tail(12)
	}
	return st
}

func (e *Engine) idleLoop() {
	for range time.Tick(20 * time.Second) {
		idle := e.store.Settings().IdleMinutes
		e.mu.Lock()
		due := idle > 0 && e.st.Status == "ready" && e.active == 0 &&
			time.Since(e.lastUsed) > time.Duration(idle)*time.Minute
		e.mu.Unlock()
		if due {
			e.Stop()
		}
	}
}

func (e *Engine) Stop() {
	e.loadMu.Lock()
	defer e.loadMu.Unlock()
	e.stopLocked()
}

func (e *Engine) stopLocked() {
	e.mu.Lock()
	cmd, exited := e.cmd, e.exited
	e.cmd, e.exited = nil, nil
	e.st = EngineState{Status: "stopped"}
	e.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	cmd.Process.Signal(os.Interrupt)
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		cmd.Process.Kill()
		<-exited
	}
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// Load makes sure the given model is the one loaded and ready.
func (e *Engine) Load(ctx context.Context, m Model) error {
	e.loadMu.Lock()
	defer e.loadMu.Unlock()

	e.mu.Lock()
	if e.st.Status == "ready" && e.st.ModelID == m.ID {
		e.lastUsed = time.Now()
		e.mu.Unlock()
		return nil
	}
	e.mu.Unlock()

	e.stopLocked()
	if !e.store.Installed(m) {
		e.fail(m.ID, "モデルがまだダウンロードされていません")
		return errors.New(e.State().Error)
	}
	rt, ok := e.store.FindRuntime()
	if !ok {
		e.fail(m.ID, "llama.cpp ランタイムが未インストールです。「モデル」タブ上部からインストールしてください")
		return errors.New(e.State().Error)
	}

	set, sys := e.store.Settings(), sysInfo()
	ctxSize := set.ContextSize
	if ctxSize == 0 {
		ctxSize = autoContext(sys.RAMTotal)
	}
	threads := set.Threads
	if threads == 0 {
		threads = sys.PerfCores
	}
	ngl := set.GPULayers
	if ngl < 0 {
		ngl = autoGPULayers()
	}
	port, err := freePort()
	if err != nil {
		return err
	}
	args := []string{
		"-m", e.store.ModelPath(m),
		"--host", "127.0.0.1", "--port", strconv.Itoa(port),
		"-c", strconv.Itoa(ctxSize),
		"-t", strconv.Itoa(threads),
		"-ngl", strconv.Itoa(ngl),
		"-np", "1", // one slot: the whole context serves one chat, smallest KV cache
	}
	args = append(args, strings.Fields(set.ExtraArgs)...)
	cmd := exec.Command(rt.Path, args...)
	log := &ringLog{}
	cmd.Stdout, cmd.Stderr = log, log
	dir := filepath.Dir(rt.Path)
	cmd.Env = append(os.Environ(), "DYLD_LIBRARY_PATH="+dir, "LD_LIBRARY_PATH="+dir)
	if err := cmd.Start(); err != nil {
		e.fail(m.ID, fmt.Sprintf("ランタイムを起動できません: %v", err))
		return err
	}
	exited := make(chan struct{})
	e.mu.Lock()
	e.cmd, e.exited, e.port, e.log = cmd, exited, port, log
	e.st = EngineState{Status: "loading", ModelID: m.ID, Context: ctxSize}
	e.mu.Unlock()
	go func() {
		werr := cmd.Wait()
		e.mu.Lock()
		if e.cmd == cmd { // died on its own (crash or out of memory)
			e.cmd, e.exited = nil, nil
			e.st = EngineState{Status: "error", ModelID: m.ID,
				Error: fmt.Sprintf("モデルのプロセスが終了しました(%v)。メモリ不足の可能性があります。より小さいモデルか、設定でコンテキスト長を下げてお試しください", werr)}
		}
		e.mu.Unlock()
		close(exited)
	}()

	// wait until the model is mapped and the server answers
	health := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	deadline := time.Now().Add(5 * time.Minute)
	for {
		select {
		case <-exited:
			return errors.New(e.State().Error)
		case <-ctx.Done():
			e.stopLocked()
			return ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
		hc, cancel := context.WithTimeout(ctx, 2*time.Second)
		req, _ := http.NewRequestWithContext(hc, "GET", health, nil)
		resp, err := http.DefaultClient.Do(req)
		cancel()
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				break
			}
		}
		if time.Now().After(deadline) {
			e.stopLocked()
			e.fail(m.ID, "モデルの読み込みが5分以内に終わりませんでした")
			return errors.New("読み込みタイムアウト")
		}
	}
	e.mu.Lock()
	e.st.Status = "ready"
	e.lastUsed = time.Now()
	e.mu.Unlock()
	return nil
}

func (e *Engine) fail(modelID, msg string) {
	e.mu.Lock()
	e.st = EngineState{Status: "error", ModelID: modelID, Error: msg}
	e.mu.Unlock()
}

// Acquire marks a request in flight and returns the server base URL.
func (e *Engine) Acquire() (base string, ctxSize int, release func(), err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.st.Status != "ready" {
		return "", 0, nil, errors.New("モデルが読み込まれていません")
	}
	e.active++
	e.lastUsed = time.Now()
	return fmt.Sprintf("http://127.0.0.1:%d", e.port), e.st.Context, func() {
		e.mu.Lock()
		e.active--
		e.lastUsed = time.Now()
		e.mu.Unlock()
	}, nil
}
