package main

import (
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"

	"github.com/disintegration/imaging"
	_ "golang.org/x/image/webp"
)

// Originals are immutable. Derivatives retain their aspect ratio so existing
// normalized crop coordinates work for both covers and thumbnails.
func (a *App) thumbnail(id, variant, mime string) (string, string, error) {
	side := 384
	if variant == "preview" {
		side = 1024
	}
	// Preserve animation rather than silently turning GIFs into still photos.
	if mime == "image/gif" {
		return filepath.Join(a.data, "media", id), mime, nil
	}
	target := filepath.Join(a.data, "media", fmt.Sprintf("%s.%s-v1", id, variant))
	resultMime := "image/jpeg"
	if mime == "image/png" || mime == "image/webp" {
		resultMime = "image/png"
	}
	if _, err := os.Stat(target); err == nil {
		return target, resultMime, nil
	}
	// Bound concurrent full-resolution decodes, and coalesce duplicate requests.
	a.thumbnailMu.Lock()
	defer a.thumbnailMu.Unlock()
	if _, err := os.Stat(target); err == nil {
		return target, resultMime, nil
	}
	original := filepath.Join(a.data, "media", id)
	file, err := os.Open(original)
	if err != nil {
		return "", "", err
	}
	config, _, err := image.DecodeConfig(file)
	file.Close()
	if err != nil {
		return "", "", err
	}
	// Avoid large allocations for unusually large uploads; keep them viewable.
	if int64(config.Width)*int64(config.Height) > 40_000_000 {
		return original, mime, nil
	}
	source, err := imaging.Open(original, imaging.AutoOrientation(true))
	if err != nil {
		return "", "", err
	}
	resized := imaging.Fit(source, side, side, imaging.Linear)
	temp, err := os.CreateTemp(filepath.Dir(target), "thumb-*")
	if err != nil {
		return "", "", err
	}
	defer os.Remove(temp.Name())
	if resultMime == "image/png" {
		err = png.Encode(temp, resized)
	} else {
		// JPEG has no alpha channel.
		opaque := imaging.New(resized.Bounds().Dx(), resized.Bounds().Dy(), color.White)
		opaque = imaging.Overlay(opaque, resized, image.Point{}, 1)
		err = jpeg.Encode(temp, opaque, &jpeg.Options{Quality: 82})
	}
	closeErr := temp.Close()
	if err != nil {
		return "", "", err
	}
	if closeErr != nil {
		return "", "", closeErr
	}
	if err = os.Rename(temp.Name(), target); err != nil {
		return "", "", err
	}
	return target, resultMime, nil
}

func (a *App) removeMediaFiles(id string) {
	for _, suffix := range []string{"", ".thumbnail-v1", ".preview-v1"} {
		_ = os.Remove(filepath.Join(a.data, "media", id+suffix))
	}
}
