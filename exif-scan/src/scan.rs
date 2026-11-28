use std::fs;
use std::io::{self, Write};
use std::path::Path;

use serde::Serialize;
use walkdir::WalkDir;

use crate::exif::{parse_exif, ExifData, ExifParseError};

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParseStatus {
    Ok,
    NoExif,
    ParseError,
}

#[derive(Debug, Serialize)]
pub struct PhotoRecord {
    pub path: String,
    pub size_bytes: u64,
    pub format: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exif: Option<ExifData>,
    pub parse_status: ParseStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn scan_dir<W: Write>(dir: &str, out: &mut W) -> io::Result<()> {
    for entry in WalkDir::new(dir)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let Some(format) = detect_format(path) else {
            continue;
        };
        let Ok(meta) = fs::metadata(path) else {
            continue;
        };
        let record = build_record(path, &format, meta.len());
        let json = serde_json::to_string(&record)
            .expect("PhotoRecord is always JSON-serializable");
        writeln!(out, "{}", json)?;
    }
    Ok(())
}

fn detect_format(path: &Path) -> Option<String> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => Some("JPEG".into()),
        "heic" | "heif" => Some("HEIC".into()),
        "png" => Some("PNG".into()),
        "tiff" | "tif" => Some("TIFF".into()),
        "dng" | "arw" | "cr2" | "cr3" | "nef" | "raf" | "orf" | "rw2" => Some("RAW".into()),
        _ => None,
    }
}

fn build_record(path: &Path, format: &str, size: u64) -> PhotoRecord {
    let (exif, status, error) = match parse_exif(path) {
        Ok(data) => (Some(data), ParseStatus::Ok, None),
        Err(ExifParseError::NotFound) => (None, ParseStatus::NoExif, None),
        Err(e) => (None, ParseStatus::ParseError, Some(e.to_string())),
    };
    PhotoRecord {
        path: path.to_string_lossy().into_owned(),
        size_bytes: size,
        format: format.to_string(),
        exif,
        parse_status: status,
        error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn detect_format_covers_common_extensions() {
        for (ext, expect) in [
            ("JPG", "JPEG"),
            ("jpeg", "JPEG"),
            ("heic", "HEIC"),
            ("HEIF", "HEIC"),
            ("png", "PNG"),
            ("tiff", "TIFF"),
            ("tif", "TIFF"),
            ("DNG", "RAW"),
            ("cr2", "RAW"),
            ("nef", "RAW"),
        ] {
            let p = PathBuf::from(format!("/some/file.{}", ext));
            assert_eq!(
                detect_format(&p).as_deref(),
                Some(expect),
                "ext {} should map to {}",
                ext,
                expect
            );
        }
    }

    #[test]
    fn detect_format_rejects_non_photo_extensions() {
        for ext in ["txt", "mp4", "mov", "pdf", "md", "DS_Store", ""] {
            let p = PathBuf::from(format!("/some/file.{}", ext));
            assert_eq!(
                detect_format(&p),
                None,
                "ext {} must not be classified as a photo",
                ext
            );
        }
    }

    #[test]
    fn detect_format_rejects_no_extension() {
        assert_eq!(detect_format(Path::new("/some/file")), None);
    }

    #[test]
    fn build_record_corrupted_jpeg_marks_parse_error() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), b"not a real jpeg").unwrap();
        let record = build_record(tmp.path(), "JPEG", 15);
        assert_eq!(record.parse_status, ParseStatus::ParseError);
        assert!(record.exif.is_none());
        assert!(record.error.is_some(), "parse_error record must carry an error message");
    }

    #[test]
    fn scan_dir_emits_one_line_per_photo_and_skips_non_photos() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("a.jpg"), b"not a real jpeg").unwrap();
        std::fs::write(tmp.path().join("b.heic"), b"not a real heic").unwrap();
        std::fs::write(tmp.path().join("c.txt"), b"a text file").unwrap();
        std::fs::write(tmp.path().join("README.md"), b"# docs").unwrap();
        // nested directory with another photo and a non-photo
        std::fs::create_dir(tmp.path().join("nested")).unwrap();
        std::fs::write(tmp.path().join("nested/d.png"), b"not a real png").unwrap();
        std::fs::write(tmp.path().join("nested/e.mp4"), b"not a real video").unwrap();

        let mut out = Vec::new();
        scan_dir(tmp.path().to_str().unwrap(), &mut out).unwrap();
        let text = String::from_utf8(out).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3, "expected 3 photo records, got {:?}", lines);

        let mut formats = std::collections::HashSet::new();
        for line in lines {
            let v: serde_json::Value = serde_json::from_str(line).unwrap();
            formats.insert(v["format"].as_str().unwrap().to_string());
            assert_eq!(
                v["parse_status"].as_str().unwrap(),
                "parse_error",
                "fake payloads should all fail to parse: {}",
                line
            );
        }
        assert_eq!(
            formats,
            ["JPEG", "HEIC", "PNG"]
                .iter()
                .map(|s| s.to_string())
                .collect()
        );
    }

    #[test]
    fn scan_dir_on_empty_dir_emits_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let mut out = Vec::new();
        scan_dir(tmp.path().to_str().unwrap(), &mut out).unwrap();
        assert!(out.is_empty());
    }

    #[test]
    fn scan_dir_on_missing_dir_emits_nothing_and_does_not_error() {
        // walkdir surfaces the error as a filtered iterator item; filter_map(Ok)
        // means scan_dir treats a missing root as "empty tree". Confirming that
        // behavior is intentional and documented by the test.
        let mut out = Vec::new();
        scan_dir("/definitely/not/a/real/path/anywhere", &mut out).unwrap();
        assert!(out.is_empty());
    }
}
