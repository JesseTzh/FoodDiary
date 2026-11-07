package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestThumbnailDimensionsAndDiskReuse(t *testing.T) {
	a := &App{data: t.TempDir()}
	if err := os.MkdirAll(filepath.Join(a.data, "media"), 0755); err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(a.data, "media", "photo")
	source := image.NewNRGBA(image.Rect(0, 0, 1600, 1200))
	source.Set(10, 10, color.NRGBA{R: 255, A: 128})
	f, err := os.Create(original)
	if err != nil {
		t.Fatal(err)
	}
	if err = png.Encode(f, source); err != nil {
		t.Fatal(err)
	}
	f.Close()
	for _, test := range []struct {
		variant       string
		width, height int
	}{{"thumbnail", 384, 288}, {"preview", 1024, 768}} {
		path, mime, err := a.thumbnail("photo", test.variant, "image/png")
		if err != nil {
			t.Fatal(err)
		}
		if mime != "image/png" {
			t.Fatalf("mime %s", mime)
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		config, _, err := image.DecodeConfig(file)
		file.Close()
		if err != nil || config.Width != test.width || config.Height != test.height {
			t.Fatalf("dimensions: %+v %v", config, err)
		}
		before, _ := os.Stat(path)
		again, _, err := a.thumbnail("photo", test.variant, "image/png")
		after, _ := os.Stat(again)
		if err != nil || again != path || !before.ModTime().Equal(after.ModTime()) {
			t.Fatal("thumbnail was regenerated")
		}
	}
	if _, err := os.Stat(original); err != nil {
		t.Fatal("original changed", err)
	}
	a.removeMediaFiles("photo")
	files, _ := os.ReadDir(filepath.Dir(original))
	if len(files) != 0 {
		t.Fatalf("derivatives not removed: %v", files)
	}
}
