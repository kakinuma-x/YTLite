// MameLLM (豆LLM): a tiny local LLM chat app for Macs with little memory.
//
// One dependency-free binary serves a local web UI, downloads small GGUF
// models from many mirrors, and drives llama.cpp's llama-server.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

const version = "0.1.0"

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	if err := cmd.Start(); err == nil {
		go cmd.Wait()
	}
}

// isMameLLM reports whether another instance of this app answers at url.
func isMameLLM(url string) bool {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(url + "api/ping")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.Header.Get("X-MameLLM") != ""
}

func main() {
	port := flag.Int("port", 11500, "待ち受けポート(使用中なら次の空きポート)")
	dataDir := flag.String("data", defaultDataDir(), "モデルと設定の保存先")
	noOpen := flag.Bool("no-open", false, "ブラウザを自動で開かない")
	showVer := flag.Bool("version", false, "バージョンを表示")
	flag.Parse()
	if *showVer {
		fmt.Println("MameLLM", version)
		return
	}

	store, err := openStore(*dataDir)
	if err != nil {
		log.Fatalf("初期化に失敗しました: %v", err)
	}
	var ln net.Listener
	for p := *port; p < *port+20; p++ {
		if ln, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p)); err == nil {
			break
		}
		// Already running (e.g. the app was double-clicked again): reuse it.
		if u := fmt.Sprintf("http://127.0.0.1:%d/", p); isMameLLM(u) {
			fmt.Println("すでに起動しています:", u)
			if !*noOpen {
				openBrowser(u)
			}
			return
		}
	}
	if ln == nil {
		log.Fatalf("ポートを開けません: %v", err)
	}
	app := &App{store: store, dl: &Downloader{store: store}, engine: newEngine(store), addr: ln.Addr().String()}
	url := "http://" + app.addr + "/"

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		app.engine.Stop() // never leave a model process behind
		os.Exit(0)
	}()

	fmt.Printf("MameLLM %s\n  画面:   %s\n  データ: %s\n  終了:   Ctrl+C\n", version, url, store.dir)
	if !*noOpen {
		openBrowser(url)
	}
	log.Fatal(http.Serve(ln, app.handler()))
}
