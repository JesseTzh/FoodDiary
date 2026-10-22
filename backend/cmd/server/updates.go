package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Set by the image build; an unversioned development server has updates disabled.
var buildCommit string
var buildReleaseTag string

const maxAPKSize = 512 << 20

var commitPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var repoPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

type androidRelease struct {
	Commit      string `json:"commit"`
	Version     string `json:"version"`
	VersionCode int64  `json:"version_code"`
	APK         string `json:"apk"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
	AssetID     int64  `json:"-"`
}

type githubAsset struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size"`
}

type androidUpdater struct {
	repo, tag, commit, token, cacheDir string
	client                             *http.Client
	mu                                 sync.Mutex
	release                            *androidRelease
	checked                            time.Time
	lookupError                        error
	downloadMu                         sync.Mutex
}

func newAndroidUpdater(data string) *androidUpdater {
	repo := os.Getenv("FOODDIARY_UPDATE_REPOSITORY")
	if repo == "" {
		repo = "JesseTzh/FoodDiary"
	}
	tag := os.Getenv("FOODDIARY_UPDATE_TAG")
	if tag == "" {
		tag = buildReleaseTag
	}
	if tag == "" && buildCommit != "" {
		tag = "ci-" + buildCommit
	}
	return &androidUpdater{repo: repo, tag: tag, commit: buildCommit,
		token: os.Getenv("FOODDIARY_GITHUB_TOKEN"), cacheDir: filepath.Join(data, "updates"),
		client: &http.Client{Timeout: 10 * time.Minute},
	}
}

// Always use the GitHub API asset ID, never a URL supplied by the client or manifest.
func (u *androidUpdater) github(ctx context.Context, path, accept string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/repos/"+u.repo+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", "FoodDiary-Updater")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if u.token != "" {
		req.Header.Set("Authorization", "Bearer "+u.token)
	}
	res, err := u.client.Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, fmt.Errorf("GitHub returned %d", res.StatusCode)
	}
	return res, nil
}

func (u *androidUpdater) latest(ctx context.Context) (selected *androidRelease, lookupErr error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.lookupError != nil && time.Since(u.checked) < 30*time.Second {
		return nil, u.lookupError
	}
	defer func() {
		if lookupErr != nil {
			u.checked, u.lookupError = time.Now(), lookupErr
		}
	}()
	if u.lookupError == nil && u.release != nil && time.Since(u.checked) < 5*time.Minute {
		return u.release, nil
	}
	if !repoPattern.MatchString(u.repo) {
		return nil, fmt.Errorf("invalid update repository")
	}
	res, err := u.github(ctx, "/releases/tags/"+url.PathEscape(u.tag), "application/vnd.github+json")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var release struct {
		Draft  bool          `json:"draft"`
		Assets []githubAsset `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 2<<20)).Decode(&release); err != nil {
		return nil, err
	}
	if release.Draft {
		return nil, fmt.Errorf("release is a draft")
	}
	var manifestID int64
	for _, a := range release.Assets {
		if a.Name == "android-update.json" {
			manifestID = a.ID
		}
	}
	if manifestID <= 0 {
		return nil, fmt.Errorf("release has no update manifest")
	}
	manifest, err := u.github(ctx, fmt.Sprintf("/releases/assets/%d", manifestID), "application/octet-stream")
	if err != nil {
		return nil, err
	}
	defer manifest.Body.Close()
	var info androidRelease
	if err := json.NewDecoder(io.LimitReader(manifest.Body, 64<<10)).Decode(&info); err != nil {
		return nil, err
	}
	if !commitPattern.MatchString(info.Commit) || !digestPattern.MatchString(info.SHA256) ||
		info.Version == "" || len(info.Version) > 200 || info.VersionCode <= 0 || info.Size <= 0 || info.Size > maxAPKSize ||
		filepath.Base(info.APK) != info.APK || !strings.HasSuffix(info.APK, ".apk") {
		return nil, fmt.Errorf("invalid update manifest")
	}
	if u.commit != "" && info.Commit != u.commit {
		return nil, fmt.Errorf("APK commit does not match server")
	}
	for _, a := range release.Assets {
		if a.Name == info.APK && a.Size == info.Size {
			info.AssetID = a.ID
		}
	}
	if info.AssetID <= 0 {
		return nil, fmt.Errorf("APK asset missing or size mismatch")
	}
	u.release, u.checked, u.lookupError = &info, time.Now(), nil
	return u.release, nil
}

func (a *App) androidUpdate(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	u := a.updater
	if u == nil || u.tag == "" {
		writeJSON(w, 200, map[string]any{"enabled": false})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	info, err := u.latest(ctx)
	if err != nil {
		log.Printf("Android update lookup: %v", err)
		errJSON(w, 503, "UPDATE_UNAVAILABLE", "更新包暂未就绪，请稍后重试")
		return
	}
	writeJSON(w, 200, map[string]any{"enabled": true, "release": info})
}

func (u *androidUpdater) cachedAPK(ctx context.Context, info *androidRelease) (*os.File, error) {
	u.downloadMu.Lock()
	defer u.downloadMu.Unlock()
	path := filepath.Join(u.cacheDir, info.SHA256+".apk")
	if f, err := os.Open(path); err == nil {
		// Recheck persisted data before serving, including after a server restart.
		h := sha256.New()
		n, err := io.Copy(h, f)
		if err == nil && n == info.Size && hex.EncodeToString(h.Sum(nil)) == info.SHA256 {
			_, err = f.Seek(0, io.SeekStart)
			if err == nil {
				return f, nil
			}
		}
		f.Close()
		os.Remove(path)
	}
	if err := os.MkdirAll(u.cacheDir, 0700); err != nil {
		return nil, err
	}
	res, err := u.github(ctx, fmt.Sprintf("/releases/assets/%d", info.AssetID), "application/octet-stream")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	tmp, err := os.CreateTemp(u.cacheDir, ".apk-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(res.Body, info.Size+1))
	if err != nil {
		return nil, err
	}
	if n != info.Size || hex.EncodeToString(h.Sum(nil)) != info.SHA256 {
		return nil, fmt.Errorf("APK checksum or size mismatch")
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return nil, err
	}
	// Keep disk usage bounded to the selected package. Open downloads remain valid.
	old, _ := filepath.Glob(filepath.Join(u.cacheDir, "*.apk"))
	for _, p := range old {
		if p != path {
			os.Remove(p)
		}
	}
	return os.Open(path)
}

func (a *App) androidDownload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	u := a.updater
	if u == nil || u.tag == "" {
		errJSON(w, 404, "UPDATE_DISABLED", "未启用应用更新")
		return
	}
	digest := r.URL.Query().Get("sha256")
	if !digestPattern.MatchString(digest) {
		errJSON(w, 400, "VALIDATION_ERROR", "缺少有效的安装包校验值")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	info, err := u.latest(ctx)
	if err != nil {
		errJSON(w, 503, "UPDATE_UNAVAILABLE", "更新包暂未就绪，请稍后重试")
		return
	}
	if digest != info.SHA256 {
		errJSON(w, 409, "UPDATE_CHANGED", "更新版本已变化，请重新检查更新")
		return
	}
	f, err := u.cachedAPK(ctx, info)
	if err != nil {
		log.Printf("Android APK download: %v", err)
		errJSON(w, 502, "UPDATE_DOWNLOAD_FAILED", "获取更新包失败，请稍后重试")
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", `attachment; filename="fooddiary-update.apk"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, info.APK, time.Time{}, f)
}
