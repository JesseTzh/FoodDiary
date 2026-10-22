package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type updateTransport func(*http.Request) (*http.Response, error)

func (f updateTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func updateFixture(t *testing.T) (*App, *androidRelease, *atomic.Int32) {
	t.Helper()
	apk := []byte("verified APK fixture")
	sum := sha256.Sum256(apk)
	info := &androidRelease{Commit: strings.Repeat("a", 40), Version: "Ver:test", VersionCode: 42,
		APK: "fooddiary-test-android.apk", SHA256: hex.EncodeToString(sum[:]), Size: int64(len(apk))}
	count := &atomic.Int32{}
	u := &androidUpdater{repo: "JesseTzh/FoodDiary", tag: "ci-" + info.Commit, commit: info.Commit, token: "server-only-secret", cacheDir: filepath.Join(t.TempDir(), "updates")}
	u.client = &http.Client{Transport: updateTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.github.com" {
			t.Errorf("unexpected host: %s", r.URL.Host)
		}
		if r.Header.Get("Authorization") != "Bearer server-only-secret" {
			t.Error("missing server-side token")
		}
		var body []byte
		switch r.URL.Path {
		case "/repos/JesseTzh/FoodDiary/releases/tags/" + u.tag:
			body, _ = json.Marshal(map[string]any{"assets": []githubAsset{{ID: 1, Name: "android-update.json"}, {ID: 2, Name: info.APK, Size: info.Size}}})
		case "/repos/JesseTzh/FoodDiary/releases/assets/1":
			body, _ = json.Marshal(info)
		case "/repos/JesseTzh/FoodDiary/releases/assets/2":
			count.Add(1)
			body = apk
		default:
			return nil, fmt.Errorf("unexpected GitHub path: %s", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(body))}, nil
	})}
	return &App{updater: u}, info, count
}

func TestAndroidUpdateCheckAndDownload(t *testing.T) {
	a, info, fetches := updateFixture(t)
	w := httptest.NewRecorder()
	routes(a).ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/updates/android", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), info.Commit) || strings.Contains(w.Body.String(), "server-only-secret") {
		t.Fatalf("update response: %d %s", w.Code, w.Body.String())
	}
	if fetches.Load() != 0 {
		t.Fatal("checking must not download APK")
	}
	downloadURL := "/api/v1/updates/android/download?sha256=" + info.SHA256
	w = httptest.NewRecorder()
	a.androidDownload(w, httptest.NewRequest("GET", downloadURL, nil))
	if w.Code != 200 || w.Body.String() != "verified APK fixture" {
		t.Fatalf("download: %d %s", w.Code, w.Body.String())
	}
	// Range requests use the verified disk cache and support resuming.
	req := httptest.NewRequest("GET", downloadURL, nil)
	req.Header.Set("Range", "bytes=0-7")
	w = httptest.NewRecorder()
	a.androidDownload(w, req)
	if w.Code != 206 || w.Body.String() != "verified" || fetches.Load() != 1 {
		t.Fatalf("cached range: %d %q, fetches=%d", w.Code, w.Body.String(), fetches.Load())
	}
	// A corrupt cache entry must be downloaded and verified again.
	if err := os.WriteFile(filepath.Join(a.updater.cacheDir, info.SHA256+".apk"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	a.androidDownload(w, httptest.NewRequest("GET", downloadURL, nil))
	if w.Code != 200 || fetches.Load() != 2 {
		t.Fatalf("corrupt cache recovery: %d, fetches=%d", w.Code, fetches.Load())
	}
}

func TestAndroidConcurrentDownloadsShareFetch(t *testing.T) {
	a, info, fetches := updateFixture(t)
	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			a.androidDownload(w, httptest.NewRequest("GET", "/download?sha256="+info.SHA256, nil))
			if w.Code != 200 {
				t.Errorf("download status %d", w.Code)
			}
		}()
	}
	wg.Wait()
	if fetches.Load() != 1 {
		t.Fatalf("downloaded %d times", fetches.Load())
	}
}

func TestAndroidUpdateRejectsInvalidReleases(t *testing.T) {
	for _, test := range []string{"wrong commit", "bad digest", "missing asset", "oversized", "upstream failure"} {
		t.Run(test, func(t *testing.T) {
			a, info, fetches := updateFixture(t)
			switch test {
			case "wrong commit":
				a.updater.commit = strings.Repeat("b", 40)
			case "bad digest":
				info.SHA256 = "no"
			case "missing asset":
				info.APK = "../evil.apk"
			case "oversized":
				info.Size = maxAPKSize + 1
			case "upstream failure":
				a.updater.client.Transport = updateTransport(func(*http.Request) (*http.Response, error) {
					return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader("missing"))}, nil
				})
			}
			w := httptest.NewRecorder()
			a.androidUpdate(w, httptest.NewRequest("GET", "/updates/android", nil))
			if w.Code != 503 || fetches.Load() != 0 {
				t.Fatalf("invalid release: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestAndroidDownloadRejectsChangedOrCorruptPackage(t *testing.T) {
	for _, test := range []string{"missing digest", "changed digest", "corrupt APK", "truncated APK"} {
		t.Run(test, func(t *testing.T) {
			a, info, fetches := updateFixture(t)
			digest := info.SHA256
			status := 502
			switch test {
			case "missing digest":
				digest, status = "", 400
			case "changed digest":
				digest, status = strings.Repeat("f", 64), 409
			case "corrupt APK":
				info.SHA256 = strings.Repeat("f", 64)
				digest = info.SHA256
			case "truncated APK":
				info.Size++
			}
			w := httptest.NewRecorder()
			a.androidDownload(w, httptest.NewRequest("GET", "/download?sha256="+digest, nil))
			if w.Code != status {
				t.Fatalf("status: %d %s", w.Code, w.Body.String())
			}
			files, _ := filepath.Glob(filepath.Join(a.updater.cacheDir, "*"))
			if len(files) != 0 {
				t.Fatalf("invalid package was retained: %v", files)
			}
			if status < 500 && fetches.Load() != 0 {
				t.Fatal("invalid request downloaded APK")
			}
		})
	}
}

func TestAndroidUpdateDisabled(t *testing.T) {
	w := httptest.NewRecorder()
	(&App{}).androidUpdate(w, httptest.NewRequest("GET", "/updates/android", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Fatalf("disabled: %s", w.Body.String())
	}
}

func TestAndroidUpdateCachesFailedLookups(t *testing.T) {
	a, _, _ := updateFixture(t)
	var calls int
	original := a.updater.client.Transport
	a.updater.client.Transport = updateTransport(func(*http.Request) (*http.Response, error) {
		calls++
		return nil, fmt.Errorf("GitHub unavailable")
	})
	for range 2 {
		if _, err := a.updater.latest(t.Context()); err == nil {
			t.Fatal("expected failure")
		}
	}
	if calls != 1 {
		t.Fatalf("repeated failing lookup called GitHub %d times", calls)
	}
	a.updater.checked = time.Now().Add(-31 * time.Second)
	a.updater.client.Transport = original
	if _, err := a.updater.latest(t.Context()); err != nil {
		t.Fatalf("did not recover after failure cache expiry: %v", err)
	}
	// Successful metadata is served without additional upstream calls.
	a.updater.client.Transport = updateTransport(func(*http.Request) (*http.Response, error) {
		t.Error("successful metadata cache was bypassed")
		return nil, fmt.Errorf("unexpected request")
	})
	if _, err := a.updater.latest(t.Context()); err != nil {
		t.Fatal(err)
	}
}
