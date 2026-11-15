package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
)

//go:embed catalog/sources.json
var builtinSourcesJSON []byte

//go:embed catalog/models.json
var builtinModelsJSON []byte

// Source is a place models (or the llama.cpp runtime) can be downloaded from.
//
// Kinds:
//
//	hf            Hugging Face compatible hub: {base}/{repo}/resolve/main/{file}
//	modelscope    ModelScope: {base}/models/{repo}/resolve/master/{file}
//	ollama        Ollama (OCI) registry: GGUF blob resolved through the manifest
//	template      custom URL template with {repo} and {file} placeholders
//	url           per-model direct URLs
//	github        GitHub releases (runtime)
//	github-mirror prefix proxy in front of github.com (runtime)
type Source struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	Base       string `json:"base"`
	Note       string `json:"note,omitempty"`
	Search     bool   `json:"search,omitempty"`
	Runtime    bool   `json:"runtime,omitempty"`
	Unofficial bool   `json:"unofficial,omitempty"`
	DefaultOff bool   `json:"default_off,omitempty"`
	Builtin    bool   `json:"builtin"`
	Enabled    bool   `json:"enabled"`
}

// Ref says where one model lives for a given kind of source.
type Ref struct {
	Kind         string `json:"kind"` // hf | ollama | url
	Repo         string `json:"repo,omitempty"`
	File         string `json:"file,omitempty"`
	Ref          string `json:"ref,omitempty"` // ollama "name:tag"
	URL          string `json:"url,omitempty"`
	Size         int64  `json:"size,omitempty"`
	SHA256       string `json:"sha256,omitempty"`
	NoModelScope bool   `json:"no_modelscope,omitempty"`
}

type Model struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Params      string   `json:"params,omitempty"`
	Description string   `json:"description,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	License     string   `json:"license,omitempty"`
	File        string   `json:"file"`
	Size        int64    `json:"size,omitempty"`
	Refs        []Ref    `json:"refs,omitempty"`
	LocalPath   string   `json:"local_path,omitempty"` // registered in place, not downloaded
	Custom      bool     `json:"custom,omitempty"`
}

type Settings struct {
	ContextSize  int     `json:"context_size"` // 0 = auto from RAM
	Threads      int     `json:"threads"`      // 0 = auto
	GPULayers    int     `json:"gpu_layers"`   // -1 = auto
	IdleMinutes  int     `json:"idle_minutes"` // unload model after this idle time; 0 = never
	MaxTokens    int     `json:"max_tokens"`
	Temperature  float64 `json:"temperature"`
	SystemPrompt string  `json:"system_prompt"`
	RuntimePath  string  `json:"runtime_path"` // explicit llama-server path
	ExtraArgs    string  `json:"extra_args"`
	HFToken      string  `json:"hf_token"`
}

type fileConfig struct {
	Sources     []Source        `json:"sources"`      // user-added
	Enabled     map[string]bool `json:"enabled"`      // overrides for any source
	SourceOrder []string        `json:"source_order"` // priority
	Models      []Model         `json:"models"`       // user-added
	Settings    Settings        `json:"settings"`
}

type Store struct {
	mu      sync.Mutex
	dir     string
	cfg     fileConfig
	builtin []Source
	catalog []Model
}

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "MameLLM")
	}
	if x := os.Getenv("XDG_DATA_HOME"); x != "" {
		return filepath.Join(x, "mamellm")
	}
	return filepath.Join(home, ".local", "share", "mamellm")
}

func openStore(dir string) (*Store, error) {
	s := &Store{dir: dir}
	for _, d := range []string{dir, s.ModelsDir(), s.RuntimeDir()} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	if err := json.Unmarshal(builtinSourcesJSON, &s.builtin); err != nil {
		return nil, fmt.Errorf("sources.json: %w", err)
	}
	for i := range s.builtin {
		s.builtin[i].Builtin = true
		s.builtin[i].Enabled = !s.builtin[i].DefaultOff
	}
	if err := json.Unmarshal(builtinModelsJSON, &s.catalog); err != nil {
		return nil, fmt.Errorf("models.json: %w", err)
	}
	s.cfg.Settings = Settings{GPULayers: -1, IdleMinutes: 10, MaxTokens: 1024, Temperature: 0.7}
	b, err := os.ReadFile(s.configPath())
	if err == nil {
		if err := json.Unmarshal(b, &s.cfg); err != nil {
			return nil, fmt.Errorf("%s が壊れています: %w", s.configPath(), err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if s.cfg.Enabled == nil {
		s.cfg.Enabled = map[string]bool{}
	}
	return s, nil
}

func (s *Store) configPath() string { return filepath.Join(s.dir, "config.json") }
func (s *Store) ModelsDir() string  { return filepath.Join(s.dir, "models") }
func (s *Store) RuntimeDir() string { return filepath.Join(s.dir, "runtime") }

// saveLocked writes the config atomically. Caller holds s.mu.
func (s *Store) saveLocked() error {
	b, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.configPath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.configPath())
}

// Sources returns every source in priority order with enabled flags applied.
func (s *Store) Sources() []Source {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sourcesLocked()
}

func (s *Store) sourcesLocked() []Source {
	all := append(append([]Source{}, s.builtin...), s.cfg.Sources...)
	byID := map[string]Source{}
	for _, src := range all {
		if en, ok := s.cfg.Enabled[src.ID]; ok {
			src.Enabled = en
		}
		byID[src.ID] = src
	}
	var out []Source
	seen := map[string]bool{}
	for _, id := range s.cfg.SourceOrder {
		if src, ok := byID[id]; ok && !seen[id] {
			out = append(out, src)
			seen[id] = true
		}
	}
	for _, src := range all {
		if !seen[src.ID] {
			out = append(out, byID[src.ID])
			seen[src.ID] = true
		}
	}
	return out
}

func (s *Store) Source(id string) (Source, bool) {
	for _, src := range s.Sources() {
		if src.ID == id {
			return src, true
		}
	}
	return Source{}, false
}

var idRe = regexp.MustCompile(`[^a-z0-9._-]+`)

func slug(s string) string {
	s = strings.Trim(idRe.ReplaceAllString(strings.ToLower(s), "-"), "-.")
	if s == "" {
		s = "item"
	}
	return s
}

func checkHTTPURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("http(s) のURLを指定してください: %q", raw)
	}
	return nil
}

func (s *Store) AddSource(src Source) (Source, error) {
	src.Name = strings.TrimSpace(src.Name)
	src.Base = strings.TrimSpace(src.Base)
	if src.Name == "" {
		return src, errors.New("名前を入力してください")
	}
	switch src.Kind {
	case "hf", "modelscope", "ollama":
		src.Base = strings.TrimRight(src.Base, "/")
		src.Search = src.Kind == "hf"
	case "template":
		if !strings.Contains(src.Base, "{file}") {
			return src, errors.New("テンプレートURLには {file} を含めてください(例: https://example.com/{repo}/{file})")
		}
	case "github-mirror":
		src.Runtime = true
		if !strings.HasSuffix(src.Base, "/") {
			src.Base += "/"
		}
	default:
		return src, fmt.Errorf("未対応の種類です: %q", src.Kind)
	}
	probe := strings.NewReplacer("{repo}", "r", "{file}", "f").Replace(src.Base)
	if err := checkHTTPURL(probe); err != nil {
		return src, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	base := "user-" + slug(src.Name)
	src.ID = base
	for n := 2; s.hasSourceLocked(src.ID); n++ {
		src.ID = fmt.Sprintf("%s-%d", base, n)
	}
	src.Builtin, src.Enabled, src.Unofficial = false, true, false
	s.cfg.Sources = append(s.cfg.Sources, src)
	return src, s.saveLocked()
}

func (s *Store) hasSourceLocked(id string) bool {
	for _, x := range s.sourcesLocked() {
		if x.ID == id {
			return true
		}
	}
	return false
}

func (s *Store) RemoveSource(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, x := range s.cfg.Sources {
		if x.ID == id {
			s.cfg.Sources = append(s.cfg.Sources[:i], s.cfg.Sources[i+1:]...)
			delete(s.cfg.Enabled, id)
			return s.saveLocked()
		}
	}
	return errors.New("組み込みのダウンロード元は削除できません(無効化はできます)")
}

func (s *Store) SetSourceEnabled(id string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.hasSourceLocked(id) {
		return errors.New("ダウンロード元が見つかりません")
	}
	s.cfg.Enabled[id] = on
	return s.saveLocked()
}

// MoveSource shifts a source up (-1) or down (+1) in priority.
func (s *Store) MoveSource(id string, dir int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := s.sourcesLocked()
	idx := -1
	for i, x := range cur {
		if x.ID == id {
			idx = i
		}
	}
	if idx < 0 {
		return errors.New("ダウンロード元が見つかりません")
	}
	// swap with the nearest neighbour of the same group (model vs runtime)
	j := idx + dir
	for j >= 0 && j < len(cur) && cur[j].Runtime != cur[idx].Runtime {
		j += dir
	}
	if j < 0 || j >= len(cur) {
		return nil
	}
	cur[idx], cur[j] = cur[j], cur[idx]
	s.cfg.SourceOrder = s.cfg.SourceOrder[:0]
	for _, x := range cur {
		s.cfg.SourceOrder = append(s.cfg.SourceOrder, x.ID)
	}
	return s.saveLocked()
}

func (s *Store) Models() []Model {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(append([]Model{}, s.catalog...), s.cfg.Models...)
}

func (s *Store) Model(id string) (Model, bool) {
	for _, m := range s.Models() {
		if m.ID == id {
			return m, true
		}
	}
	return Model{}, false
}

// ModelPath is where the model's GGUF lives (or will live) on disk.
func (s *Store) ModelPath(m Model) string {
	if m.LocalPath != "" {
		return m.LocalPath
	}
	return filepath.Join(s.ModelsDir(), m.File)
}

func (s *Store) Installed(m Model) bool {
	st, err := os.Stat(s.ModelPath(m))
	return err == nil && st.Mode().IsRegular()
}

var fileRe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func safeFileName(name string) string {
	name = fileRe.ReplaceAllString(filepath.Base(strings.ReplaceAll(name, "\\", "/")), "_")
	name = strings.TrimLeft(name, ".")
	if name == "" {
		name = "model"
	}
	if !strings.HasSuffix(strings.ToLower(name), ".gguf") {
		name += ".gguf"
	}
	return name
}

// AddModel registers a user model. Exactly one of the ref kinds or a local
// path must be given.
func (s *Store) AddModel(m Model) (Model, error) {
	m.Name = strings.TrimSpace(m.Name)
	m.Custom = true
	if m.LocalPath != "" {
		st, err := os.Stat(m.LocalPath)
		if err != nil || !st.Mode().IsRegular() {
			return m, fmt.Errorf("ファイルが見つかりません: %s", m.LocalPath)
		}
		if !strings.HasSuffix(strings.ToLower(m.LocalPath), ".gguf") {
			return m, errors.New(".gguf ファイルを指定してください")
		}
		m.Size, m.File, m.Refs = st.Size(), filepath.Base(m.LocalPath), nil
	} else {
		if len(m.Refs) != 1 {
			return m, errors.New("ダウンロード情報が不正です")
		}
		r := &m.Refs[0]
		switch r.Kind {
		case "hf":
			r.Repo, r.File = strings.Trim(strings.TrimSpace(r.Repo), "/"), strings.TrimLeft(strings.TrimSpace(r.File), "/")
			if strings.Count(r.Repo, "/") != 1 || r.File == "" || strings.Contains(r.Repo+r.File, "..") {
				return m, errors.New("リポジトリは「所有者/名前」、ファイルはGGUFのパスで指定してください")
			}
			m.File = safeFileName(r.File)
		case "ollama":
			r.Ref = strings.TrimSpace(r.Ref)
			if _, _, _, err := parseOllamaRef(r.Ref); err != nil {
				return m, err
			}
			m.File = safeFileName("ollama-" + r.Ref)
		case "url":
			r.URL = strings.TrimSpace(r.URL)
			if err := checkHTTPURL(r.URL); err != nil {
				return m, err
			}
			u, _ := url.Parse(r.URL)
			m.File = safeFileName(u.Path)
		default:
			return m, fmt.Errorf("未対応の種類です: %q", r.Kind)
		}
		if m.Size == 0 {
			m.Size = r.Size
		}
	}
	if m.Name == "" {
		m.Name = strings.TrimSuffix(m.File, ".gguf")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	all := append(append([]Model{}, s.catalog...), s.cfg.Models...)
	base := "user-" + slug(strings.TrimSuffix(m.File, ".gguf"))
	m.ID = base
	for n := 2; ; n++ {
		clash := false
		for _, x := range all {
			if x.ID == m.ID {
				clash = true
			}
		}
		if !clash {
			break
		}
		m.ID = fmt.Sprintf("%s-%d", base, n)
	}
	// never let two models share (and overwrite) one file on disk
	if m.LocalPath == "" {
		stem := strings.TrimSuffix(m.File, ".gguf")
		for n := 2; ; n++ {
			clash := false
			for _, x := range all {
				if x.LocalPath == "" && strings.EqualFold(x.File, m.File) {
					clash = true
				}
			}
			if !clash {
				break
			}
			m.File = fmt.Sprintf("%s-%d.gguf", stem, n)
		}
	}
	s.cfg.Models = append(s.cfg.Models, m)
	return m, s.saveLocked()
}

func (s *Store) RemoveModel(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, x := range s.cfg.Models {
		if x.ID == id {
			s.cfg.Models = append(s.cfg.Models[:i], s.cfg.Models[i+1:]...)
			return s.saveLocked()
		}
	}
	return errors.New("カタログ内蔵のモデルは一覧から削除できません")
}

func (s *Store) Settings() Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg.Settings
}

func (s *Store) SetSettings(v Settings) error {
	if v.ContextSize < 0 || v.ContextSize > 131072 || v.Threads < 0 || v.Threads > 256 ||
		v.GPULayers < -1 || v.IdleMinutes < 0 || v.MaxTokens < 0 || v.Temperature < 0 || v.Temperature > 2 {
		return errors.New("設定値が範囲外です")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.Settings = v
	return s.saveLocked()
}
