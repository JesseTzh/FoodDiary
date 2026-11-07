package main

import (
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// HTTP decoding runs in the browser's network stack, keeping font decompression
// out of the Flutter/Skia main-thread font parser. Sidecars are generated at build.
func serveWebFile(w http.ResponseWriter, r *http.Request, path string) {
	// Identity responses also vary, so shared caches do not reuse them for
	// clients that accept a compressed representation (or vice versa).
	w.Header().Add("Vary", "Accept-Encoding")
	if r.Header.Get("Range") == "" {
		br := encodingQuality(r.Header.Get("Accept-Encoding"), "br")
		gz := encodingQuality(r.Header.Get("Accept-Encoding"), "gzip")
		encodings := []struct {
			name, suffix string
			quality      float64
		}{{"br", ".br", br}, {"gzip", ".gz", gz}}
		if gz > br {
			encodings[0], encodings[1] = encodings[1], encodings[0]
		}
		for _, encoding := range encodings {
			if encoding.quality <= 0 {
				continue
			}
			if _, err := os.Stat(path + encoding.suffix); err != nil {
				continue
			}
			contentType := mime.TypeByExtension(filepath.Ext(path))
			if contentType == "" {
				contentType = "application/octet-stream"
			}
			w.Header().Set("Content-Type", contentType)
			w.Header().Set("Content-Encoding", encoding.name)
			http.ServeFile(w, r, path+encoding.suffix)
			return
		}
	}
	http.ServeFile(w, r, path)
}

func encodingQuality(header, encoding string) float64 {
	wildcard := 0.0
	for _, part := range strings.Split(header, ",") {
		fields := strings.Split(part, ";")
		name := strings.TrimSpace(fields[0])
		quality := 1.0
		for _, parameter := range fields[1:] {
			key, value, found := strings.Cut(strings.TrimSpace(parameter), "=")
			if found && key == "q" {
				q, err := strconv.ParseFloat(value, 64)
				if err != nil || q < 0 || q > 1 {
					quality = 0
				} else {
					quality = q
				}
			}
		}
		if name == encoding {
			return quality
		}
		if name == "*" {
			wildcard = quality
		}
	}
	return wildcard
}
