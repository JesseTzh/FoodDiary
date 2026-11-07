package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrecompressedWebFileKeepsMimeAndBody(t *testing.T) {
	root := t.TempDir()
	t.Setenv("FOODDIARY_FRONTEND_DIR", root)
	path := filepath.Join(root, "main.dart.js")
	source := []byte("console.log('precompressed fixture');")
	if err := os.WriteFile(path, source, 0600); err != nil {
		t.Fatal(err)
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(source); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".gz", compressed.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/main.dart.js", nil)
	req.Header.Set("Accept-Encoding", "br;q=0, gzip;q=1")
	routes(&App{}).ServeHTTP(response, req)
	if response.Header().Get("Content-Encoding") != "gzip" || !strings.Contains(response.Header().Get("Content-Type"), "javascript") {
		t.Fatal(response.Header())
	}
	if !bytes.Equal(response.Body.Bytes(), compressed.Bytes()) {
		t.Fatal("precompressed bytes changed")
	}
}

func TestEncodingNegotiation(t *testing.T) {
	for _, test := range []struct {
		header, encoding string
		want             float64
	}{
		{"gzip, br", "br", 1}, {"br;q=0, gzip", "br", 0},
		{"br;q=0.5, gzip;q=1", "br", .5}, {"*;q=0.2", "br", .2},
		{"gzip", "br", 0}, {"br;q=invalid", "br", 0},
	} {
		if got := encodingQuality(test.header, test.encoding); got != test.want {
			t.Errorf("%q: got %v want %v", test.header, got, test.want)
		}
	}
}

func TestWebIdentityAndRangeResponses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "font.ttf")
	if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".br", []byte("compressed"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, partial := range []bool{false, true} {
		req := httptest.NewRequest("GET", "/font.ttf", nil)
		want := "original"
		if partial {
			req.Header.Set("Accept-Encoding", "br")
			req.Header.Set("Range", "bytes=0-2")
			want = "ori"
		}
		response := httptest.NewRecorder()
		serveWebFile(response, req, path)
		if response.Body.String() != want || response.Header().Get("Content-Encoding") != "" {
			t.Fatal(response.Header(), response.Body.String())
		}
		if !strings.Contains(response.Header().Get("Vary"), "Accept-Encoding") {
			t.Fatal("identity response must vary on Accept-Encoding")
		}
	}
}

func TestWebDeliveryCompressionAndIsolation(t *testing.T) {
	root := t.TempDir()
	t.Setenv("FOODDIARY_FRONTEND_DIR", root)
	source := strings.Repeat("console.log('fooddiary');\n", 200)
	if err := os.WriteFile(filepath.Join(root, "main.dart.js"), []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/main.dart.js", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	response := httptest.NewRecorder()
	routes(&App{}).ServeHTTP(response, req)
	if response.Code != 200 {
		t.Fatal(response.Code)
	}
	for name, value := range map[string]string{
		"Content-Encoding":             "gzip",
		"Cross-Origin-Opener-Policy":   "same-origin",
		"Cross-Origin-Embedder-Policy": "require-corp",
	} {
		if response.Header().Get(name) != value {
			t.Errorf("%s = %q", name, response.Header().Get(name))
		}
	}
	reader, err := gzip.NewReader(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	body, err := io.ReadAll(reader)
	if err != nil || string(body) != source {
		t.Fatalf("compressed content changed: %v", err)
	}
}
