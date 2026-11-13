# S3 Build Cache (Bitrise Step)

A Bitrise Step that restores and saves build caches (Gradle dependencies, the Gradle build cache, ccache and CocoaPods) in S3-compatible storage such as MinIO, AWS S3 or Cloudflare R2.

Work in progress; the first release will be 0.1.0.

## Configuration

Add the non-secret settings as app variables in `bitrise.yml`:

```yaml
app:
  envs:
  - S3_CACHE_ENDPOINT: https://minio.example.com   # leave empty for AWS S3
  - S3_CACHE_BUCKET: build-caches
  - S3_CACHE_PREFIX: my-app
  - S3_CACHE_REGION: us-east-1
```

Add these two as secrets in the Bitrise UI (Workflow Editor, Secrets):

- `S3_CACHE_ACCESS_KEY_ID`
- `S3_CACHE_SECRET_ACCESS_KEY`

The prefix must be unique per app. Apps that share a bucket and a prefix share and overwrite each other's caches.

### Pull request builds

Bitrise does not expose secrets to pull request builds unless "Expose for Pull Requests" is enabled for the secret. Without the credentials the step skips all work, prints a notice and does not fail the build. Enable the option only if pull requests from untrusted forks cannot run your workflow.

### Inputs

| Input | Default | Description |
|---|---|---|
| `mode` | `restore` | `restore` or `save` |
| `caches` | empty | Newline-separated: `gradle-deps`, `gradle-build-cache`, `ccache`, `cocoapods` |
| `endpoint` | `$S3_CACHE_ENDPOINT` | Storage endpoint URL; empty means AWS S3 |
| `bucket` | `$S3_CACHE_BUCKET` | Bucket name |
| `prefix` | `$S3_CACHE_PREFIX` | Key prefix inside the bucket |
| `region` | `$S3_CACHE_REGION` | Region; empty means `us-east-1` |
| `access_key_id` | `$S3_CACHE_ACCESS_KEY_ID` | Access key ID (secret) |
| `secret_access_key` | `$S3_CACHE_SECRET_ACCESS_KEY` | Secret access key (secret) |
| `gradle_key_files` | `android/gradle.properties`, `android/build.gradle`, `android/app/build.gradle`, `pnpm-lock.yaml` | Newline-separated files that form the Gradle dependency key |
| `gradle_key_ignore_pattern` | `^\s*(versionCode\|versionName)\b` | Lines matching this expression are ignored when hashing |
| `fallback_branch` | `main` | Branch used when the current branch has no cache |
| `cocoapods_lockfile` | `ios/Podfile.lock` | Lockfile that forms the CocoaPods key |
| `cocoapods_dir` | `ios/Pods` | Directory cached for CocoaPods |
| `ccache_max_size` | `5G` | Value for `ccache --max-size` |
| `connect_timeout` | `10` | Storage connection timeout in seconds |
