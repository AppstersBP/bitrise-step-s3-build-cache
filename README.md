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

## Log messages

Every line the step prints starts with `[s3-build-cache]` or, for a cache, `[s3-build-cache:<cache>]`. `<...>` marks a value that differs per build. The last line of a run summarises the outcome, for example `restore: gradle-deps=exact, ccache=none`.

### General

| Message | Meaning |
|---|---|
| `Missing S3 build cache settings:` followed by a list | A required input is empty or invalid. This is the only message that fails the build. |
| `Skipping the S3 build cache: the secrets S3_CACHE_ACCESS_KEY_ID and S3_CACHE_SECRET_ACCESS_KEY are empty in this pull request build.` | A pull request build without credentials. All selected caches are reported as `skipped`. |
| `Bitrise does not expose secrets to pull request builds unless "Expose for Pull Requests" is enabled for them, so these secrets are not available to pull request builds.` | Second line of the same notice. |
| `Storage: bucket <bucket> at <endpoint> (path-style addressing)` / `Storage: bucket <bucket> on AWS S3, region <region>` | The storage that is used. Credentials in the endpoint are not printed. |
| `S3 storage is unreachable at <endpoint> — restoring no caches` / `— saving no caches` | The bucket did not answer within about 5 seconds. All selected caches are reported as `skipped` and the build continues. |
| `Cannot create a temporary directory for the AWS configuration.` | The temporary AWS configuration could not be created. |
| `Cannot prepare the storage access, continuing without caches` | Follows the line above. All selected caches are reported as `skipped`. |
| `<mode>: <cache>=<result>, ...` | Summary of the run. |
| `BITRISE_GIT_BRANCH is empty, using the branch name "unknown"` | The branch is not known; branch-keyed caches use `unknown`. |
| `key file not found, skipped: <file>` | A file listed in `gradle_key_files` does not exist. |
| `none of the key files exist` / `cannot read the key files` / `cannot compute the SHA-256` / `invalid ignore pattern: <pattern>` | The cache key could not be computed. |
| `[s3-build-cache:<cache>] failed unexpectedly (exit status <n>), continuing without it` | An internal error in one cache. The cache is reported as `none` (restore) or `failed` (save) and the other caches still run. |
| `[s3-build-cache:<cache>] set no result, continuing without it` | A cache finished without reporting a result. It is reported as `none` (restore) or `failed` (save). |
| `archive_create: ...`, `archive_extract: ...` | The archive could not be created, or it is damaged or cannot be extracted. |
| `envman could not set <name>` | An output or variable could not be exported. |

### All caches

| Message | Meaning |
|---|---|
| `cannot create a temporary file` | No space or permission for the temporary archive. |
| `restored <key> (<n> bytes)` | An archive was downloaded and extracted. |
| `archive <key> is damaged or could not be extracted` | The download was not usable; the next candidate is tried. |
| `no cache found (looked for <key>)` | There is no cache for this key or branch and nothing to fall back to. |
| `no cache found (newest archive <key> was already tried)` | The newest stored archive was one that had already failed. |
| `could not list stored archives, nothing restored` | The listing of the prefix failed. |
| `fallback <key> could not be restored` | The newest stored archive could not be restored. |
| `uploaded <key> (<n> bytes)` | A new archive was saved. |
| `upload of <key> failed` | The upload failed; the result is `failed`. |
| `could not create the archive` | The archive could not be built; the result is `failed`. |

### gradle-deps

| Message | Meaning |
|---|---|
| `no Gradle key file found, restore skipped` / `save skipped` | None of the key files exist, so there is no key. |
| `nothing to save: ~/.gradle/caches and ~/.gradle/wrapper do not exist` | The build produced no Gradle files. |
| `cache <key> is current, date renewed` | The archive for this key already exists; its date was renewed and nothing was uploaded (`refreshed`). |
| `could not renew the date of <key>` | Renewing failed; the existing archive is kept. |

### gradle-build-cache

| Message | Meaning |
|---|---|
| `build cache enabled in <file>` | `org.gradle.caching=true` was added to the Gradle properties of the build machine. |
| `cannot create <dir>, build cache not enabled` / `could not update gradle.properties` | The Gradle build cache could not be switched on. |
| `nothing to save: ~/.gradle/caches/build-cache-1 does not exist` | The build did not fill the build cache. |

### ccache

| Message | Meaning |
|---|---|
| `ccache not found, installing it with apt-get` / `with brew` | ccache is installed when it is missing. |
| `installing ccache failed: <reason>` | Installation failed; the restore continues without ccache. |
| `cannot create ~/.ccache` / `could not export the ccache variables` | The build could not be set up to use ccache. |
| `ccache --max-size=<size> failed` / `ccache --zero-stats failed` / `ccache --show-stats failed` | A ccache command failed. |
| `ccache is not installed, nothing to save` / `nothing to save: ~/.ccache does not exist` | There is nothing to upload. |

### cocoapods

| Message | Meaning |
|---|---|
| `warning: lock file <file> not found, restore skipped` / `lock file <file> not found, save skipped` | The lockfile that forms the key is missing. |
| `no cache restored (looked for <key>)` | There is no cache for this lockfile. CocoaPods caches have no fallback. |
| `warning: the CocoaPods directory is empty, skipped` | `cocoapods_dir` is empty. |
| `warning: the CocoaPods directory <dir> is the source directory, skipped` / `is the root directory, skipped` / `leaves the source directory, skipped` | The directory is refused because archiving or restoring it would be unsafe. |
| `nothing to save: <dir> does not exist` | The build produced no Pods directory. |
| `cache <key> is current, date renewed` / `could not renew the date of <key>` | As for `gradle-deps`. |

## Removing old caches

The step never deletes anything from the bucket. Archives of old branches and old dependency sets stay until the storage removes them, so set a lifecycle rule on the bucket that expires objects below the prefix of your project.

Saving an unchanged `gradle-deps` or `cocoapods` archive renews its date (`date renewed`), and the branch-keyed caches (`gradle-build-cache`, `ccache`) are uploaded again on every save. Archives that are saved (or, for `gradle-deps` and `cocoapods`, reused unchanged) at least every N days are therefore not removed by a rule of N days.

MinIO, with the MinIO client (`<N>` is the number of days):

```sh
mc ilm rule add --expire-days <N> --prefix "<prefix>/" <alias>/<bucket>
```

AWS S3: add a lifecycle configuration to the bucket (Management, Lifecycle rules) with a filter on the prefix `<prefix>/` and an Expiration action that expires current versions after N days. With versioning enabled, also add a rule that permanently deletes noncurrent versions.

Cloudflare R2: open the bucket, then Settings, Object lifecycle rules, add a rule with the prefix `<prefix>/` and the action "Delete uploaded objects" after N days.

A value of 30 days is a reasonable start for a project that builds every few days.
