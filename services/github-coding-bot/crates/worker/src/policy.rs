use std::{collections::HashSet, path::Component, path::Path};

use globset::{GlobBuilder, GlobSet, GlobSetBuilder};
use thiserror::Error;

pub struct PathPolicy {
    blocked: GlobSet,
}

impl PathPolicy {
    pub fn new(patterns: &[String]) -> Result<Self, PolicyError> {
        let mut builder = GlobSetBuilder::new();
        for pattern in patterns {
            let glob = GlobBuilder::new(pattern)
                .literal_separator(true)
                .case_insensitive(true)
                .build()
                .map_err(|error| PolicyError::InvalidGlob {
                    pattern: pattern.clone(),
                    reason: error.to_string(),
                })?;
            builder.add(glob);
        }
        Ok(Self {
            blocked: builder.build().map_err(|error| PolicyError::InvalidGlob {
                pattern: "<set>".to_owned(),
                reason: error.to_string(),
            })?,
        })
    }

    pub fn validate_relative(&self, value: &str) -> Result<String, PolicyError> {
        if value.is_empty() || value.contains('\0') || value.contains('\\') {
            return Err(PolicyError::UnsafePath(value.to_owned()));
        }
        let path = Path::new(value);
        if path.is_absolute() {
            return Err(PolicyError::UnsafePath(value.to_owned()));
        }
        let mut components = Vec::new();
        for component in path.components() {
            match component {
                Component::Normal(component) => {
                    let component = component
                        .to_str()
                        .ok_or_else(|| PolicyError::UnsafePath(value.to_owned()))?;
                    components.push(component);
                }
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(PolicyError::UnsafePath(value.to_owned()))
                }
            }
        }
        if components.is_empty() {
            return Ok(".".to_owned());
        }
        let normalized = components.join("/");
        if normalized == ".git" || normalized.starts_with(".git/") {
            return Err(PolicyError::BlockedPath(normalized));
        }
        if self.blocked.is_match(&normalized) {
            return Err(PolicyError::BlockedPath(normalized));
        }
        Ok(normalized)
    }

    pub fn validate_patch(&self, patch: &str) -> Result<(), PolicyError> {
        if patch.contains("new file mode 120000")
            || patch.contains("new mode 120000")
            || patch.contains("GIT binary patch")
        {
            return Err(PolicyError::UnsafePatch(
                "symlink and binary patches are disabled".to_owned(),
            ));
        }

        let mut paths = HashSet::new();
        for line in patch.lines() {
            if let Some(value) = line.strip_prefix("diff --git ") {
                let mut headers = value.split_ascii_whitespace();
                let (Some(old), Some(new), None) = (headers.next(), headers.next(), headers.next())
                else {
                    return Err(PolicyError::UnsafePatch(
                        "malformed or quoted diff header paths are not supported".to_owned(),
                    ));
                };
                collect_patch_path(old, &mut paths)?;
                collect_patch_path(new, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("+++ ") {
                collect_patch_path(value, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("--- ") {
                collect_patch_path(value, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("rename from ") {
                collect_metadata_path(value, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("rename to ") {
                collect_metadata_path(value, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("copy from ") {
                collect_metadata_path(value, &mut paths)?;
            } else if let Some(value) = line.strip_prefix("copy to ") {
                collect_metadata_path(value, &mut paths)?;
            }
        }
        if paths.is_empty() {
            return Err(PolicyError::UnsafePatch(
                "patch did not contain file headers".to_owned(),
            ));
        }
        for path in paths {
            self.validate_relative(&path)?;
        }
        Ok(())
    }

    pub fn validate_changed_files<'a>(
        &self,
        paths: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), PolicyError> {
        for path in paths {
            self.validate_relative(path)?;
        }
        Ok(())
    }
}

fn collect_metadata_path(value: &str, paths: &mut HashSet<String>) -> Result<(), PolicyError> {
    if value.starts_with('"') || value.contains('\0') {
        return Err(PolicyError::UnsafePatch(
            "quoted or NUL-containing metadata paths are not supported".to_owned(),
        ));
    }
    paths.insert(value.to_owned());
    Ok(())
}

fn collect_patch_path(value: &str, paths: &mut HashSet<String>) -> Result<(), PolicyError> {
    let value = value.split('\t').next().unwrap_or(value);
    if value == "/dev/null" {
        return Ok(());
    }
    if value.starts_with('"') || value.contains(char::is_whitespace) {
        return Err(PolicyError::UnsafePatch(
            "quoted or whitespace-containing patch paths are not supported".to_owned(),
        ));
    }
    let value = value
        .strip_prefix("a/")
        .or_else(|| value.strip_prefix("b/"))
        .ok_or_else(|| PolicyError::UnsafePatch("file path lacked a/ or b/ prefix".to_owned()))?;
    paths.insert(value.to_owned());
    Ok(())
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PolicyError {
    #[error("invalid blocked-path glob `{pattern}`: {reason}")]
    InvalidGlob { pattern: String, reason: String },
    #[error("unsafe repository-relative path `{0}`")]
    UnsafePath(String),
    #[error("path `{0}` is protected")]
    BlockedPath(String),
    #[error("unsafe patch: {0}")]
    UnsafePatch(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> PathPolicy {
        let result = PathPolicy::new(&[
            ".github/workflows/**".to_owned(),
            "deploy/**".to_owned(),
            "*secret*".to_owned(),
        ]);
        match result {
            Ok(policy) => policy,
            Err(error) => panic!("test policy failed: {error}"),
        }
    }

    #[test]
    fn rejects_path_traversal_and_absolute_paths() {
        let policy = policy();
        assert!(matches!(
            policy.validate_relative("../outside"),
            Err(PolicyError::UnsafePath(_))
        ));
        assert!(matches!(
            policy.validate_relative("/etc/passwd"),
            Err(PolicyError::UnsafePath(_))
        ));
        assert!(matches!(
            policy.validate_relative("src\\..\\secret"),
            Err(PolicyError::UnsafePath(_))
        ));
    }

    #[test]
    fn enforces_blocked_paths_in_patches() {
        let patch = "--- a/.github/workflows/ci.yml\n+++ b/.github/workflows/ci.yml\n@@ -1 +1 @@\n-old\n+new\n";
        assert!(matches!(
            policy().validate_patch(patch),
            Err(PolicyError::BlockedPath(_))
        ));
    }

    #[test]
    fn rejects_symlink_patches() {
        let patch = "diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+../../outside\n";
        assert!(matches!(
            policy().validate_patch(patch),
            Err(PolicyError::UnsafePatch(_))
        ));
    }

    #[test]
    fn rejects_copy_metadata_that_mentions_a_protected_path() {
        let patch = "diff --git a/safe.txt b/copy.txt\nsimilarity index 100%\ncopy from deploy/secret.txt\ncopy to copy.txt\ndiff --git a/other.txt b/other.txt\n--- a/other.txt\n+++ b/other.txt\n@@ -1 +1 @@\n-old\n+new\n";
        assert!(matches!(
            policy().validate_patch(patch),
            Err(PolicyError::BlockedPath(_))
        ));
    }

    #[test]
    fn rejects_quoted_metadata_paths_instead_of_misvalidating_them() {
        let patch = "diff --git a/safe.txt b/copy.txt\nsimilarity index 100%\ncopy from \"deploy/secret file\"\ncopy to copy.txt\n";
        assert!(matches!(
            policy().validate_patch(patch),
            Err(PolicyError::UnsafePatch(_))
        ));
    }

    #[test]
    fn rejects_mode_only_changes_to_protected_paths() {
        let patch = "diff --git a/deploy/release.sh b/deploy/release.sh\nold mode 100644\nnew mode 100755\n";
        assert!(matches!(
            policy().validate_patch(patch),
            Err(PolicyError::BlockedPath(_))
        ));
    }
}
