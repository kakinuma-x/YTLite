package main

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestCatalogIsValid(t *testing.T) {
	var srcs []Source
	if err := json.Unmarshal(builtinSourcesJSON, &srcs); err != nil {
		t.Fatal(err)
	}
	var models []Model
	if err := json.Unmarshal(builtinModelsJSON, &models); err != nil {
		t.Fatal(err)
	}
	ids, files := map[string]bool{}, map[string]bool{}
	for _, s := range srcs {
		if ids[s.ID] || s.Name == "" || s.Kind == "" {
			t.Errorf("bad or duplicate source %q", s.ID)
		}
		ids[s.ID] = true
	}
	for _, m := range models {
		if files[strings.ToLower(m.File)] || m.Size <= 0 || len(m.Refs) == 0 || !strings.HasSuffix(m.File, ".gguf") {
			t.Errorf("bad model entry %q", m.ID)
		}
		files[strings.ToLower(m.File)] = true
		if r := m.Refs[0]; r.Kind != "hf" || len(r.SHA256) != 64 {
			t.Errorf("%s: first ref must be a hashed Hugging Face file", m.ID)
		}
	}
}

func TestFit(t *testing.T) {
	cases := []struct {
		sizeMB, ramGB int64
		want          string
	}{
		{270, 4, "good"},   // SmolLM2 360M on a 4GB Mac
		{1100, 4, "ok"},    // 1.5B on 4GB
		{2000, 4, "tight"}, // 3B on 4GB
		{2500, 4, "no"},    // 4B on 4GB
		{2000, 8, "good"},  // 3B on 8GB
		{2500, 8, "ok"},    // 4B on 8GB
		{4900, 8, "tight"}, // 8B on 8GB
		{4900, 4, "no"},
	}
	for _, c := range cases {
		if got := fit(c.sizeMB<<20, c.ramGB*gib); got != c.want {
			t.Errorf("fit(%dMB, %dGB) = %s, want %s", c.sizeMB, c.ramGB, got, c.want)
		}
	}
}

func TestTrimHistory(t *testing.T) {
	big := strings.Repeat("あ", 3000) // ≈3000 tokens
	msgs := []chatMsg{{"system", "sys"}}
	for i := 0; i < 10; i++ {
		msgs = append(msgs, chatMsg{"user", big}, chatMsg{"assistant", big})
	}
	msgs = append(msgs, chatMsg{"user", "last"})
	out := trimHistory(msgs, 7000)
	if out[0].Role != "system" || out[len(out)-1].Content != "last" || out[1].Role != "user" {
		t.Fatalf("bad shape: %d messages, second role %s", len(out), out[1].Role)
	}
	if len(out) != 4 {
		t.Errorf("kept %d messages, want 4", len(out))
	}
	// an oversized final message is still sent rather than dropped
	if out := trimHistory([]chatMsg{{"user", big}}, 100); len(out) != 1 {
		t.Errorf("last message dropped")
	}
}

func TestNamesAndPaths(t *testing.T) {
	for in, want := range map[string]string{
		"sub/dir/Model-Q4_K_M.gguf": "Model-Q4_K_M.gguf",
		"../../etc/passwd":          "passwd.gguf",
		"..hidden.GGUF":             "hidden.GGUF",
		"gemma3:1b":                 "gemma3_1b.gguf",
	} {
		if got := safeFileName(in); got != want {
			t.Errorf("safeFileName(%q) = %q, want %q", in, got, want)
		}
	}
	root := filepath.FromSlash("/data/runtime/b1")
	if !inside(root, filepath.Join(root, "a/b")) || inside(root, filepath.Join(root, "../b2/x")) || inside(root, "/etc/passwd") {
		t.Error("inside() path containment is wrong")
	}
	if ns, name, tag, err := parseOllamaRef("gemma3"); err != nil || ns != "library" || name != "gemma3" || tag != "latest" {
		t.Errorf("parseOllamaRef default: %s %s %s %v", ns, name, tag, err)
	}
	if ns, name, tag, _ := parseOllamaRef("user/model:q4"); ns != "user" || name != "model" || tag != "q4" {
		t.Errorf("parseOllamaRef namespaced: %s %s %s", ns, name, tag)
	}
	if _, _, _, err := parseOllamaRef("a/b/c:../x"); err == nil {
		t.Error("parseOllamaRef accepted a bad ref")
	}
}

func TestStoreSourcesAndModels(t *testing.T) {
	s, err := openStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	n := len(s.Sources())
	src, err := s.AddSource(Source{Name: "My Mirror", Kind: "hf", Base: "https://mirror.example/"})
	if err != nil || src.Base != "https://mirror.example" {
		t.Fatalf("AddSource: %+v %v", src, err)
	}
	if _, err := s.AddSource(Source{Name: "x", Kind: "hf", Base: "ftp://x"}); err == nil {
		t.Error("non-http source accepted")
	}
	if err := s.MoveSource(src.ID, -1); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSourceEnabled("huggingface", false); err != nil {
		t.Fatal(err)
	}
	m, err := s.AddModel(Model{Refs: []Ref{{Kind: "hf", Repo: "bartowski/SmolLM2-135M-Instruct-GGUF", File: "SmolLM2-135M-Instruct-Q4_K_M.gguf"}}})
	if err != nil || m.File == "SmolLM2-135M-Instruct-Q4_K_M.gguf" {
		t.Fatalf("custom model must not share a catalog file: %+v %v", m, err)
	}
	// everything survives a restart
	s2, err := openStore(s.dir)
	if err != nil {
		t.Fatal(err)
	}
	all := s2.Sources()
	if len(all) != n+1 {
		t.Fatalf("got %d sources, want %d", len(all), n+1)
	}
	for _, x := range all {
		if x.ID == "huggingface" && x.Enabled {
			t.Error("disabled flag not persisted")
		}
	}
	if _, ok := s2.Model(m.ID); !ok {
		t.Error("custom model not persisted")
	}
	if err := s2.RemoveSource("huggingface"); err == nil {
		t.Error("built-in source was removable")
	}
	if err := s2.RemoveSource(src.ID); err != nil {
		t.Error(err)
	}
}
