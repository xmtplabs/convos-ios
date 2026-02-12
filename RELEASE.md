# Release Process

This document describes the automated release process for the Convos iOS app.

## Quick Start

```bash
make tag-release      # Creates release branch and PR
# [Merge the PR on GitHub]
# [Tag is created automatically on merge]
make promote-release  # Fast-forward merge dev to main
```

## Release Workflow

### Overview

The release process uses a PR-based workflow to work with protected branches:

```
1. make tag-release     → Creates release branch + PR
2. [User merges PR on GitHub]
3. [GitHub Actions auto-creates tag on merge]
4. make promote-release  → Fast-forward merges dev to main
```

### Step-by-Step

1. **Prepare Release**:
   - Ensure all features are merged to `dev` branch
   - Test dev build on TestFlight
   - Decide on version number (semantic versioning)

2. **Create Release PR**:
   ```bash
   make tag-release
   ```

   This will:
   - Ensure you're on the `dev` branch
   - Create a `release/<version>` branch
   - Update version in Xcode project
   - Commit the version change
   - Push the branch to origin
   - Create a PR from `release/<version>` to `dev`

3. **Merge the PR**:
   - Review the version bump PR on GitHub
   - Merge the PR (squash or regular merge)

4. **Automatic Tag Creation**:
   When the PR is merged, GitHub Actions will:
   - Extract the tag version from the PR body
   - Create and push the tag
   - Delete the release branch
   - Trigger the `auto-release.yml` workflow

5. **Automatic GitHub Release**:
   The `auto-release.yml` workflow:
   - Verifies version in `dev` branch matches the tag
   - Generates AI-powered release notes using Claude
   - Creates a GitHub Release with the generated notes
   - Triggers dev TestFlight build

6. **Promote Release to Main**:
   ```bash
   make promote-release
   ```
   - Fast-forward merges dev to main
   - Ensures the tag exists on both branches
   - Triggers prod TestFlight build

## Release Notes

The workflow generates customer-friendly release notes using AI:

- **Short, concise bullet points** (maximum 5)
- **User-focused benefits** (not technical details)
- **Warm, friendly language**
- **Each point under 15 words**
- **No technical jargon**

These notes are used for:
- GitHub Release descriptions
- App Store Connect submission (via Bitrise)
- TestFlight release notes

## Complete Release Pipeline

1. **PR Creation** → `make tag-release` creates branch and PR
2. **PR Merge** → User merges PR on GitHub
3. **Tag Creation** → GitHub Actions creates tag automatically
4. **GitHub Release** → Created with AI-generated notes
5. **Dev TestFlight** → Bitrise builds and deploys dev build
6. **Release Promotion** → `make promote-release` fast-forwards main to dev
7. **Prod TestFlight** → Bitrise builds and deploys prod build
8. **App Store Connect** → Ready for App Store submission

## GitHub Actions Workflows

### `release-tag-on-merge.yml`

Triggers when a PR from `release/*` branch is merged to `dev`:
- Extracts tag version from PR body (`<!-- release-tag: X.Y.Z -->`)
- Creates and pushes the tag
- Deletes the release branch

### `auto-release.yml`

Triggers on semantic version tags and:
- Generates AI-powered release notes using Claude
- Creates GitHub Release with generated notes
- Verifies version consistency between dev branch and tag
- Provides release notes to Bitrise for TestFlight builds

## Prerequisites

### Required Secrets

Add these secrets to your GitHub repository:

1. **`ANTHROPIC_API_KEY`** - Your Anthropic API key for generating release notes with Claude
2. **`GITHUB_TOKEN`** - Automatically provided by GitHub Actions

### Setup

```bash
make setup
```

This will install all required dependencies and set up the development environment.

## Troubleshooting

### Common Issues

1. **GitHub CLI not found**:
   - Install GitHub CLI: `brew install gh`
   - Authenticate: `gh auth login`

2. **Release branch already exists**:
   - Delete local branch: `git branch -D release/<version>`
   - Delete remote branch: `git push origin --delete release/<version>`

3. **Anthropic API errors**:
   - Check `ANTHROPIC_API_KEY` secret is set
   - Verify API key has sufficient credits
   - Check API rate limits

4. **Version mismatch**:
   - Ensure Xcode project has consistent `MARKETING_VERSION`
   - Run `make version` to check current version
   - Use `make tag-release` for proper versioning

5. **Tag not created after merge**:
   - Check GitHub Actions logs for `release-tag-on-merge` workflow
   - Verify PR body contains `<!-- release-tag: X.Y.Z -->` comment
   - Ensure PR was merged from a `release/*` branch

### Debugging

- Check Actions tab for detailed logs
- Look for specific error messages in workflow steps
- Verify repository permissions and secrets

## Best Practices

1. **Use semantic versioning** (1.0.0, 1.0.1, 1.1.0, 2.0.0)
2. **Test dev build on TestFlight** before creating release PR
3. **Review the PR** before merging to verify version is correct
4. **Test prod build on TestFlight** after `make promote-release`
5. **Review AI-generated notes** for accuracy
6. **Keep release notes user-friendly** for customer-facing content
7. **Use descriptive commit messages** for better release notes

## Support

For issues with the release process:
1. Check the Actions tab logs
2. Verify all prerequisites are met
3. Ensure secrets are properly configured
4. Check GitHub Actions documentation
