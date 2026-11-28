use std::fmt;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use exif::{In, Tag, Value};
use serde::Serialize;

#[derive(Debug, Default, Serialize, PartialEq)]
pub struct ExifData {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date_taken: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_make: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    pub gps_present: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orientation: Option<u32>,
}

#[derive(Debug)]
pub enum ExifParseError {
    Io(std::io::Error),
    NotFound,
    Malformed(String),
}

impl fmt::Display for ExifParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ExifParseError::Io(e) => write!(f, "io: {}", e),
            ExifParseError::NotFound => write!(f, "no EXIF segment"),
            ExifParseError::Malformed(m) => write!(f, "malformed: {}", m),
        }
    }
}

impl std::error::Error for ExifParseError {}

pub fn parse_exif(path: &Path) -> Result<ExifData, ExifParseError> {
    let file = File::open(path).map_err(ExifParseError::Io)?;
    let mut reader = BufReader::new(file);
    let exif_reader = exif::Reader::new();
    let exif_data = match exif_reader.read_from_container(&mut reader) {
        Ok(e) => e,
        Err(exif::Error::NotFound(_)) => return Err(ExifParseError::NotFound),
        Err(e) => return Err(ExifParseError::Malformed(e.to_string())),
    };

    let get_string = |tag: Tag| -> Option<String> {
        let field = exif_data.get_field(tag, In::PRIMARY)?;
        let raw = field.display_value().to_string();
        let trimmed = raw.trim().trim_matches('"').to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    };

    let get_uint = |tag: Tag| -> Option<u32> {
        exif_data
            .get_field(tag, In::PRIMARY)
            .and_then(|f| f.value.get_uint(0))
    };

    let date_taken = get_string(Tag::DateTimeOriginal).or_else(|| get_string(Tag::DateTime));
    let camera_make = get_string(Tag::Make);
    let camera_model = get_string(Tag::Model);

    let width = get_uint(Tag::PixelXDimension).or_else(|| get_uint(Tag::ImageWidth));
    let height = get_uint(Tag::PixelYDimension).or_else(|| get_uint(Tag::ImageLength));

    let gps_present = has_gps(&exif_data);
    let orientation = get_uint(Tag::Orientation);

    Ok(ExifData {
        date_taken,
        camera_make,
        camera_model,
        width,
        height,
        gps_present,
        orientation,
    })
}

fn has_gps(exif_data: &exif::Exif) -> bool {
    let Some(lat_field) = exif_data.get_field(Tag::GPSLatitude, In::PRIMARY) else {
        return false;
    };
    matches!(&lat_field.value, Value::Rational(v) if v.len() >= 3)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_exif_on_missing_file_returns_io_error() {
        let err = parse_exif(Path::new("/no/such/path/at/all.jpg")).unwrap_err();
        assert!(matches!(err, ExifParseError::Io(_)), "got {:?}", err);
    }

    #[test]
    fn parse_exif_on_garbage_bytes_returns_malformed() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), b"garbage not even close to a jpeg").unwrap();
        let err = parse_exif(tmp.path()).unwrap_err();
        assert!(matches!(err, ExifParseError::Malformed(_)), "got {:?}", err);
    }

    #[test]
    fn exif_data_serializes_with_snake_case_and_skips_none() {
        let data = ExifData {
            date_taken: Some("2024:03:15 14:22:11".into()),
            camera_make: Some("Apple".into()),
            camera_model: None,
            width: Some(4032),
            height: Some(3024),
            gps_present: true,
            orientation: None,
        };
        let json = serde_json::to_value(&data).unwrap();
        assert_eq!(json["date_taken"], "2024:03:15 14:22:11");
        assert_eq!(json["camera_make"], "Apple");
        assert!(json.get("camera_model").is_none(), "None fields must be skipped");
        assert_eq!(json["width"], 4032);
        assert_eq!(json["gps_present"], true);
        assert!(json.get("orientation").is_none());
    }
}
