package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

//go:embed web
var webFS embed.FS

type App struct {
	store  *Store
	dl     *Downloader
	engine *Engine
	addr   string // host:port we listen on
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

// guard keeps other websites away from the local API: the Host header must
// be ours (DNS rebinding) and every write must carry a header that browsers
// only send cross-origin after a CORS preflight we never approve.
func (a *App) guard(next http.Handler) http.Handler {
	_, port, _ := strings.Cut(a.addr, ":")
	hosts := map[string]bool{"127.0.0.1:" + port: true, "localhost:" + port: true}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hosts[r.Host] {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if o := r.Header.Get("Origin"); r.Header.Get("X-MameLLM") != "1" || (o != "" && !hosts[strings.TrimPrefix(o, "http://")]) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) handler() http.Handler {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("/", http.FileServer(http.FS(sub)))
	mux.HandleFunc("/api/state", a.state)
	mux.HandleFunc("/api/search", a.search)
	mux.HandleFunc("/api/repo-files", a.repoFiles)
	post := func(path string, h func(r *http.Request, body json.RawMessage) (any, error)) {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				http.Error(w, "POST only", http.StatusMethodNotAllowed)
				return
			}
			body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
			if err != nil {
				writeErr(w, 400, err)
				return
			}
			if len(bytes.TrimSpace(body)) == 0 {
				body = []byte("{}")
			}
			out, err := h(r, body)
			if err != nil {
				writeErr(w, 400, err)
				return
			}
			if out == nil {
				out = map[string]bool{"ok": true}
			}
			writeJSON(w, 200, out)
		})
	}
	type idReq struct {
		ID     string `json:"id"`
		Source string `json:"source"`
		Dir    int    `json:"dir"`
		On     bool   `json:"on"`
	}
	withID := func(f func(r *http.Request, q idReq) (any, error)) func(*http.Request, json.RawMessage) (any, error) {
		return func(r *http.Request, body json.RawMessage) (any, error) {
			var q idReq
			if err := json.Unmarshal(body, &q); err != nil {
				return nil, err
			}
			return f(r, q)
		}
	}
	model := func(id string) (Model, error) {
		m, ok := a.store.Model(id)
		if !ok {
			return m, errors.New("モデルが見つかりません")
		}
		return m, nil
	}

	post("/api/models/download", withID(func(_ *http.Request, q idReq) (any, error) {
		m, err := model(q.ID)
		if err != nil {
			return nil, err
		}
		return a.dl.StartModel(m, q.Source)
	}))
	post("/api/models/delete", withID(func(_ *http.Request, q idReq) (any, error) {
		m, err := model(q.ID)
		if err != nil {
			return nil, err
		}
		if a.engine.State().ModelID == m.ID {
			a.engine.Stop()
		}
		return nil, a.dl.DeleteModelFiles(m)
	}))
	post("/api/models/remove", withID(func(_ *http.Request, q idReq) (any, error) {
		m, err := model(q.ID)
		if err != nil {
			return nil, err
		}
		if err := a.store.RemoveModel(m.ID); err != nil {
			return nil, err
		}
		if a.engine.State().ModelID == m.ID {
			a.engine.Stop()
		}
		return nil, a.dl.DeleteModelFiles(m)
	}))
	post("/api/models/add", func(_ *http.Request, body json.RawMessage) (any, error) {
		var q struct {
			Model
			Download bool `json:"download"`
		}
		if err := json.Unmarshal(body, &q); err != nil {
			return nil, err
		}
		m, err := a.store.AddModel(q.Model)
		if err != nil {
			return nil, err
		}
		if q.Download && m.LocalPath == "" {
			if _, err := a.dl.StartModel(m, ""); err != nil {
				return nil, err
			}
		}
		return m, nil
	})
	post("/api/downloads/cancel", withID(func(_ *http.Request, q idReq) (any, error) { a.dl.Cancel(q.ID); return nil, nil }))
	post("/api/downloads/dismiss", withID(func(_ *http.Request, q idReq) (any, error) { a.dl.Dismiss(q.ID); return nil, nil }))
	post("/api/sources/add", func(_ *http.Request, body json.RawMessage) (any, error) {
		var s Source
		if err := json.Unmarshal(body, &s); err != nil {
			return nil, err
		}
		return a.store.AddSource(s)
	})
	post("/api/sources/remove", withID(func(_ *http.Request, q idReq) (any, error) { return nil, a.store.RemoveSource(q.ID) }))
	post("/api/sources/enable", withID(func(_ *http.Request, q idReq) (any, error) { return nil, a.store.SetSourceEnabled(q.ID, q.On) }))
	post("/api/sources/move", withID(func(_ *http.Request, q idReq) (any, error) { return nil, a.store.MoveSource(q.ID, q.Dir) }))
	post("/api/sources/test", withID(func(r *http.Request, q idReq) (any, error) { return a.testSource(r.Context(), q.ID) }))
	post("/api/runtime/install", withID(func(_ *http.Request, q idReq) (any, error) { return a.dl.StartRuntime(q.Source) }))
	post("/api/settings", func(_ *http.Request, body json.RawMessage) (any, error) {
		s := a.store.Settings()
		if err := json.Unmarshal(body, &s); err != nil {
			return nil, err
		}
		s.RuntimePath = strings.TrimSpace(s.RuntimePath)
		s.HFToken = strings.TrimSpace(s.HFToken)
		return nil, a.store.SetSettings(s)
	})
	post("/api/engine/load", withID(func(r *http.Request, q idReq) (any, error) {
		m, err := model(q.ID)
		if err != nil {
			return nil, err
		}
		// loading outlives this request so a page reload does not abort it
		go a.engine.Load(context.Background(), m)
		return nil, nil
	}))
	post("/api/engine/stop", func(*http.Request, json.RawMessage) (any, error) { a.engine.Stop(); return nil, nil })
	post("/api/quit", func(*http.Request, json.RawMessage) (any, error) {
		go func() {
			time.Sleep(200 * time.Millisecond) // let the response out first
			a.engine.Stop()
			os.Exit(0)
		}()
		return nil, nil
	})
	mux.HandleFunc("/api/ping", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-MameLLM", version)
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/api/chat", a.chat)
	return a.guard(mux)
}

type modelView struct {
	Model
	Installed bool     `json:"installed"`
	Fit       string   `json:"fit"`
	Need      int64    `json:"need"`
	Sources   []string `json:"sources"` // ids of enabled sources that carry it
}

func (a *App) state(w http.ResponseWriter, r *http.Request) {
	sys := sysInfo()
	var models []modelView
	for _, m := range a.store.Models() {
		v := modelView{Model: m, Installed: a.store.Installed(m), Sources: []string{}}
		if v.Size == 0 && v.Installed { // size was unknown until downloaded
			if st, err := os.Stat(a.store.ModelPath(m)); err == nil {
				v.Size = st.Size()
			}
		}
		v.Fit, v.Need = fit(v.Size, sys.RAMTotal), memNeed(v.Size)
		seen := map[string]bool{}
		for _, t := range a.dl.modelTargets(m, "") {
			if !seen[t.src.ID] {
				v.Sources = append(v.Sources, t.src.ID)
				seen[t.src.ID] = true
			}
		}
		models = append(models, v)
	}
	rt, ok := a.store.FindRuntime()
	set := a.store.Settings()
	if set.HFToken != "" {
		set.HFToken = "********" // never echo the secret back to the page
	}
	_, platErr := runtimeAsset()
	writeJSON(w, 200, map[string]any{
		"version":  version,
		"data_dir": a.store.dir,
		"sys":      sys,
		"auto":     map[string]int{"context_size": autoContext(sys.RAMTotal), "threads": sys.PerfCores, "gpu_layers": autoGPULayers()},
		"settings": set,
		"sources":  a.store.Sources(),
		"models":   models,
		"runtime":  map[string]any{"found": ok, "info": rt, "installable": platErr == nil},
		"engine":   a.engine.State(),
		"jobs":     a.dl.Snapshot(),
	})
}

// searchSources lists Hugging Face compatible hubs to query, in priority order.
func (a *App) searchSources(id string) ([]Source, error) {
	var out []Source
	for _, s := range a.store.Sources() {
		if s.Kind == "hf" && s.Search && ((id == "" && s.Enabled) || s.ID == id) {
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("検索に使える(Hugging Face互換の)ダウンロード元が有効になっていません")
	}
	return out, nil
}

// hubGetAny asks each hub in turn until one answers.
func (a *App) hubGetAny(ctx context.Context, srcs []Source, path string, out any) (Source, error) {
	var last error
	for _, src := range srcs {
		if last = a.hubGet(ctx, src, path, out); last == nil {
			return src, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	return Source{}, last
}

func (a *App) hubGet(ctx context.Context, src Source, path string, out any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", src.Base+path, nil)
	req.Header.Set("User-Agent", userAgent)
	if t := a.store.Settings().HFToken; t != "" && src.ID == "huggingface" {
		req.Header.Set("Authorization", "Bearer "+t)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: HTTP %d", src.Name, resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(out)
}

func (a *App) search(w http.ResponseWriter, r *http.Request) {
	srcs, err := a.searchSources(r.URL.Query().Get("source"))
	if err != nil {
		writeErr(w, 400, err)
		return
	}
	q := url.Values{"search": {r.URL.Query().Get("q")}, "filter": {"gguf"}, "sort": {"downloads"}, "direction": {"-1"}, "limit": {"40"}}
	var res []struct {
		ID        string `json:"id"`
		Downloads int64  `json:"downloads"`
		Likes     int64  `json:"likes"`
	}
	src, err := a.hubGetAny(r.Context(), srcs, "/api/models?"+q.Encode(), &res)
	if err != nil {
		writeErr(w, 502, err)
		return
	}
	writeJSON(w, 200, map[string]any{"source": src.Name, "results": res})
}

func (a *App) repoFiles(w http.ResponseWriter, r *http.Request) {
	srcs, err := a.searchSources(r.URL.Query().Get("source"))
	if err != nil {
		writeErr(w, 400, err)
		return
	}
	repo := strings.Trim(r.URL.Query().Get("repo"), "/")
	if strings.Count(repo, "/") != 1 || strings.Contains(repo, "..") {
		writeErr(w, 400, errors.New("リポジトリ名が不正です"))
		return
	}
	var tree []struct {
		Path string `json:"path"`
		Size int64  `json:"size"`
		LFS  *struct {
			OID string `json:"oid"`
		} `json:"lfs"`
	}
	if _, err := a.hubGetAny(r.Context(), srcs, "/api/models/"+escapePath(repo)+"/tree/main?recursive=true", &tree); err != nil {
		writeErr(w, 502, err)
		return
	}
	type file struct {
		Path   string `json:"path"`
		Size   int64  `json:"size"`
		SHA256 string `json:"sha256,omitempty"`
		Fit    string `json:"fit"`
	}
	files := []file{}
	ram := sysInfo().RAMTotal
	for _, t := range tree {
		low := strings.ToLower(t.Path)
		if !strings.HasSuffix(low, ".gguf") || strings.Contains(low, "mmproj") {
			continue
		}
		f := file{Path: t.Path, Size: t.Size, Fit: fit(t.Size, ram)}
		if t.LFS != nil {
			f.SHA256 = t.LFS.OID
		}
		files = append(files, f)
	}
	writeJSON(w, 200, map[string]any{"repo": repo, "files": files})
}

// testSource checks that a source answers for a tiny well-known file.
func (a *App) testSource(ctx context.Context, id string) (any, error) {
	src, ok := a.store.Source(id)
	if !ok {
		return nil, errors.New("ダウンロード元が見つかりません")
	}
	const repo, file = "bartowski/SmolLM2-135M-Instruct-GGUF", "SmolLM2-135M-Instruct-Q4_K_M.gguf"
	var u string
	switch src.Kind {
	case "hf":
		u = src.Base + "/" + repo + "/resolve/main/" + file
	case "modelscope":
		u = src.Base + "/models/" + repo + "/resolve/master/" + file
	case "template":
		u = strings.NewReplacer("{repo}", repo, "{file}", file).Replace(src.Base)
	case "ollama":
		u = src.Base + "/v2/library/smollm2/manifests/135m"
	case "github", "github-mirror":
		u = githubURL(src, "/"+llamaRepo+"/releases/latest")
	default:
		return map[string]any{"ok": true, "detail": "モデルごとの個別URLを使います"}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	method := "HEAD"
	if src.Kind == "ollama" {
		method = "GET"
	}
	req, _ := http.NewRequestWithContext(ctx, method, u, nil)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json, */*")
	start := time.Now()
	resp, err := httpClient.Do(req)
	if err != nil {
		return map[string]any{"ok": false, "detail": err.Error()}, nil
	}
	resp.Body.Close()
	ms := time.Since(start).Milliseconds()
	good := resp.StatusCode == 200
	return map[string]any{"ok": good, "detail": fmt.Sprintf("HTTP %d・%d ms", resp.StatusCode, ms)}, nil
}

type chatMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// trimHistory drops the oldest turns so prompt + reply fit in the context.
// Tokens are estimated at one per 3 UTF-8 bytes (≈1 per Japanese character).
func trimHistory(msgs []chatMsg, budget int) []chatMsg {
	cost := func(m chatMsg) int { return len(m.Content)/3 + 8 }
	var sys []chatMsg
	rest := msgs
	if len(msgs) > 0 && msgs[0].Role == "system" {
		sys, rest = msgs[:1], msgs[1:]
		budget -= cost(msgs[0])
	}
	start := len(rest)
	for i := len(rest) - 1; i >= 0; i-- {
		budget -= cost(rest[i])
		if budget < 0 && i < len(rest)-1 {
			break
		}
		start = i
	}
	// never start on an assistant turn
	for start < len(rest)-1 && rest[start].Role != "user" {
		start++
	}
	return append(append([]chatMsg{}, sys...), rest[start:]...)
}

func (a *App) chat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var q struct {
		Model    string    `json:"model"`
		Messages []chatMsg `json:"messages"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&q); err != nil || len(q.Messages) == 0 {
		writeErr(w, 400, errors.New("リクエストが不正です"))
		return
	}
	m, ok := a.store.Model(q.Model)
	if !ok {
		writeErr(w, 400, errors.New("モデルが見つかりません"))
		return
	}
	if err := a.engine.Load(r.Context(), m); err != nil {
		writeErr(w, 500, err)
		return
	}
	base, ctxSize, release, err := a.engine.Acquire()
	if err != nil {
		writeErr(w, 500, err)
		return
	}
	defer release()

	set := a.store.Settings()
	maxTok := set.MaxTokens
	if maxTok <= 0 || maxTok > ctxSize/2 {
		maxTok = ctxSize / 2
	}
	msgs := q.Messages
	if sp := strings.TrimSpace(set.SystemPrompt); sp != "" && msgs[0].Role != "system" {
		msgs = append([]chatMsg{{Role: "system", Content: sp}}, msgs...)
	}
	msgs = trimHistory(msgs, ctxSize-maxTok-64)
	body, _ := json.Marshal(map[string]any{
		"messages": msgs, "stream": true, "max_tokens": maxTok,
		"temperature": set.Temperature, "cache_prompt": true,
	})
	req, _ := http.NewRequestWithContext(r.Context(), "POST", base+"/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		writeErr(w, 502, fmt.Errorf("モデルから応答がありません: %v", err))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		writeErr(w, 502, fmt.Errorf("モデルがエラーを返しました(HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(b))))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	fl, _ := w.(http.Flusher)
	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if fl != nil {
				fl.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}
