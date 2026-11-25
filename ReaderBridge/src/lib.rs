use std::ffi::{c_char, c_void, CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::ops::Range;
use std::os::fd::BorrowedFd;
use std::ptr;
use zimru::{Archive, ArchiveLimits, Blob, ClusterReadLimits, Entry, Item};

const MIB: u64 = 1024 * 1024;
const MAX_RESOURCE_BYTES: u64 = 32 * MIB;
const MAX_DIRECT_READ_BYTES: usize = MIB as usize;
const LIMITS: ArchiveLimits = ArchiveLimits {
    max_metadata_record_bytes: MIB as usize,
    max_entries: 40_000_000,
    max_clusters: 2_000_000,
    cluster: Some(ClusterReadLimits {
        max_stored_bytes: 64 * MIB,
        max_decoded_bytes: 64 * MIB,
        xz_memory_bytes: 64 * MIB,
        zstd_window_log: 25,
    }),
};

pub struct TFKArchive(Archive);

pub struct TFKDirectResource {
    archive: Archive,
    file_offset: u64,
    size: u64,
    mime: CString,
}

impl TFKDirectResource {
    fn open(archive: &Archive, path: &str) -> Result<Option<Self>, String> {
        let entry = archive
            .get_entry_by_path(path)
            .map_err(|error| error.to_string())?;
        let item = entry.get_item(true).map_err(|error| error.to_string())?;
        let direct = archive
            .blob_direct_access(item.cluster_index(), item.blob_index())
            .map_err(|error| error.to_string())?;
        if !direct.is_direct {
            return Ok(None);
        }
        Ok(Some(Self {
            archive: archive.clone(),
            file_offset: direct.file_offset,
            size: direct.size,
            mime: CString::new(item.mimetype()).map_err(|error| error.to_string())?,
        }))
    }

    fn read(&self, offset: u64, bytes: &mut [u8]) -> Result<(), String> {
        if bytes.len() > MAX_DIRECT_READ_BYTES {
            return Err("An archive resource read cannot exceed 1 MiB.".into());
        }
        if offset > self.size || bytes.len() as u64 > self.size - offset {
            return Err("The read exceeds the archive resource bounds.".into());
        }
        if bytes.is_empty() {
            return Ok(());
        }
        let absolute = self
            .file_offset
            .checked_add(offset)
            .ok_or("The archive resource offset is invalid.")?;
        let length = self
            .archive
            .read_at(absolute, bytes)
            .map_err(|error| error.to_string())?;
        if length != bytes.len() {
            return Err("The archive resource ended before its declared size.".into());
        }
        Ok(())
    }
}

const MAX_COMPRESSED_PDF_CLUSTER_BYTES: u64 = 256 * MIB;

struct ArchiveSlice<'a> {
    archive: &'a Archive,
    range: Range<u64>,
}

impl Read for ArchiveSlice<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let limit = (self.range.end - self.range.start).min(buffer.len() as u64) as usize;
        let count = self
            .archive
            .read_at(self.range.start, &mut buffer[..limit])
            .map_err(io::Error::other)?;
        self.range.start += count as u64;
        Ok(count)
    }
}

fn extract_compressed_pdf(
    archive: &Archive,
    path: &str,
    output: &mut impl Write,
    check_cancelled: impl Fn() -> io::Result<()>,
) -> Result<bool, String> {
    check_cancelled().map_err(|error| error.to_string())?;
    let item = archive
        .get_entry_by_path(path)
        .and_then(|entry| entry.get_item(true))
        .map_err(|error| error.to_string())?;
    if item.mimetype() != "application/pdf" {
        return Ok(false);
    }
    let mut range = archive
        .cluster_byte_range(item.cluster_index())
        .map_err(|error| error.to_string())?;
    let mut info = [0];
    if range.is_empty()
        || archive
            .read_at(range.start, &mut info)
            .map_err(|error| error.to_string())?
            != 1
    {
        return Err("The archive cluster is missing.".into());
    }
    // The low nibble identifies compression and bit 4 selects 64-bit blob offsets.
    if info[0] & 0x0f != 5 {
        return Ok(false);
    }
    if range.end - range.start > LIMITS.cluster.unwrap().max_stored_bytes {
        return Err("The compressed PDF cluster exceeds the stored size limit.".into());
    }
    range.start += 1;
    let mut decoder = zstd::stream::read::Decoder::new(ArchiveSlice { archive, range })
        .map_err(|error| error.to_string())?;
    decoder
        .window_log_max(LIMITS.cluster.unwrap().zstd_window_log)
        .map_err(|error| error.to_string())?;
    let width = if info[0] & 0x10 == 0 { 4 } else { 8 };
    extract_pdf_blob(
        &mut decoder,
        width,
        item.blob_index(),
        output,
        check_cancelled,
    )
    .map_err(|error| error.to_string())
}

fn extract_pdf_blob(
    input: &mut impl Read,
    width: usize,
    blob: u32,
    output: &mut impl Write,
    check_cancelled: impl Fn() -> io::Result<()>,
) -> io::Result<bool> {
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid compressed PDF cluster offsets.",
        )
    };
    let mut head = [0; 8];
    input.read_exact(&mut head[..width])?;
    let table_len = u64::from_le_bytes(head);
    if table_len > MAX_COMPRESSED_PDF_CLUSTER_BYTES || table_len % width as u64 != 0 {
        return Err(invalid());
    }
    let words = table_len / width as u64;
    if u64::from(blob) + 1 >= words {
        return Err(invalid());
    }

    let mut buffer = [0; 64 * 1024];
    let (mut start, mut end) = (table_len, table_len);
    let mut previous = table_len;
    let mut index = 1;
    while index < words {
        check_cancelled()?;
        let count = ((words - index) * width as u64).min(buffer.len() as u64) as usize;
        input.read_exact(&mut buffer[..count])?;
        for offset in buffer[..count].chunks_exact(width) {
            head.fill(0);
            head[..width].copy_from_slice(offset);
            let next = u64::from_le_bytes(head);
            if next < previous || next > MAX_COMPRESSED_PDF_CLUSTER_BYTES {
                return Err(invalid());
            }
            if index == u64::from(blob) {
                start = next;
            }
            if index == u64::from(blob) + 1 {
                end = next;
            }
            previous = next;
            index += 1;
        }
    }
    if end - start <= MAX_RESOURCE_BYTES {
        return Ok(false);
    }

    // Consume the entire decoded cluster, including bytes outside this blob,
    // so truncation and the frame checksum are checked before publication.
    let mut position = table_len;
    while position < previous {
        check_cancelled()?;
        let count = (previous - position).min(buffer.len() as u64) as usize;
        input.read_exact(&mut buffer[..count])?;
        let next = position + count as u64;
        let overlap_start = start.max(position);
        let overlap_end = end.min(next);
        if overlap_start < overlap_end {
            output.write_all(
                &buffer[(overlap_start - position) as usize..(overlap_end - position) as usize],
            )?;
        }
        position = next;
    }
    check_cancelled()?;
    if input.read(&mut buffer[..1])? != 0 {
        return Err(invalid());
    }
    Ok(true)
}

pub struct TFKResource {
    path: CString,
    title: CString,
    mime: CString,
    data: ResourceData,
}

enum ResourceData {
    Cluster(Blob, usize),
    DirectPrefix(Vec<u8>),
}

pub struct TFKEntryMetadata {
    path: CString,
    title: CString,
}

pub struct TFKTitleMatches(Vec<TFKEntryMetadata>);

fn item_path(item: &Item, legacy: bool) -> Result<CString, String> {
    let path = if legacy {
        format!("{}/{}", char::from(item.namespace()), item.path())
    } else {
        item.path().to_owned()
    };
    CString::new(path).map_err(|error| error.to_string())
}

fn read_item(item: Item, legacy: bool) -> Result<TFKResource, String> {
    if item.size().map_err(|error| error.to_string())? > MAX_RESOURCE_BYTES {
        return Err("This archive resource exceeds the 32 MiB reader limit.".into());
    }
    let blob = item.get_data().map_err(|error| error.to_string())?;
    let length = blob.size();
    resource(&item, legacy, ResourceData::Cluster(blob, length))
}

fn read_item_prefix(
    item: Item,
    legacy: bool,
    maximum: usize,
) -> Result<Option<TFKResource>, String> {
    let direct = item
        .archive()
        .blob_direct_access(item.cluster_index(), item.blob_index())
        .map_err(|error| error.to_string())?;
    let data = if direct.is_direct {
        let mut bytes = vec![0; direct.size.min(maximum as u64) as usize];
        let length = item
            .archive()
            .read_at(direct.file_offset, &mut bytes)
            .map_err(|error| error.to_string())?;
        if length != bytes.len() {
            return Err("The archive article ended before its declared size.".into());
        }
        ResourceData::DirectPrefix(bytes)
    } else {
        let blob = match item.get_data() {
            Ok(blob) => blob,
            // An unreadable or over-budget compressed cluster must not block other articles.
            Err(zimru::Error::Decompression(_)) => return Ok(None),
            Err(error) => return Err(error.to_string()),
        };
        let length = blob.size().min(maximum);
        ResourceData::Cluster(blob, length)
    };
    resource(&item, legacy, data).map(Some)
}

fn resource(item: &Item, legacy: bool, data: ResourceData) -> Result<TFKResource, String> {
    Ok(TFKResource {
        path: item_path(item, legacy)?,
        title: CString::new(item.title()).map_err(|error| error.to_string())?,
        mime: CString::new(item.mimetype()).map_err(|error| error.to_string())?,
        data,
    })
}

fn entry_resource(entry: zimru::Result<Entry>, legacy: bool) -> Result<TFKResource, String> {
    let entry = entry.map_err(|error| error.to_string())?;
    read_item(
        entry.get_item(true).map_err(|error| error.to_string())?,
        legacy,
    )
}

unsafe fn write_error(error: *mut *mut c_char, message: String) {
    if !error.is_null() {
        *error = CString::new(message)
            .unwrap_or_else(|_| CString::new("Could not read the ZIM archive.").unwrap())
            .into_raw();
    }
}

unsafe fn return_result<T>(result: Result<T, String>, error: *mut *mut c_char) -> *mut T {
    match result {
        Ok(value) => Box::into_raw(Box::new(value)),
        Err(message) => {
            write_error(error, message);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_open(
    file: *const c_char,
    error: *mut *mut c_char,
) -> *mut TFKArchive {
    let result = (|| {
        let path = CStr::from_ptr(file)
            .to_str()
            .map_err(|error| error.to_string())?;
        let file = File::open(path).map_err(|error| error.to_string())?;
        let archive =
            Archive::from_file_with_limits(file, LIMITS).map_err(|error| error.to_string())?;
        archive.set_cluster_cache_max_bytes((16 * MIB) as usize);
        Ok(TFKArchive(archive))
    })();
    return_result(result, error)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_close(archive: *mut TFKArchive) {
    drop(Box::from_raw(archive));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_entry_count(archive: &TFKArchive) -> u32 {
    archive.0.entry_count()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_verify_checksum(archive: &TFKArchive) -> *mut c_char {
    let archive = &archive.0;
    let message = if !archive.has_checksum() {
        "This ZIM archive does not contain a checksum.".to_owned()
    } else if archive.header().checksum_pos.checked_add(16) != Some(archive.file_len()) {
        "The ZIM checksum is not at the end of the archive. The file may be damaged.".to_owned()
    } else {
        match archive.check() {
            Ok(true) => return ptr::null_mut(),
            Ok(false) => "The ZIM archive does not match its embedded checksum.".to_owned(),
            Err(error) => format!("The ZIM checksum could not be verified. {error}"),
        }
    };
    CString::new(message)
        .unwrap_or_else(|_| CString::new("The ZIM checksum could not be verified.").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_title(archive: &TFKArchive) -> *mut c_char {
    archive
        .0
        .metadata_str("Title")
        .ok()
        .and_then(|title| CString::new(title).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_main(
    archive: &TFKArchive,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    return_result(
        entry_resource(
            archive.0.main_entry(),
            !archive.0.header().uses_new_namespaces(),
        ),
        error,
    )
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_resource(
    archive: &TFKArchive,
    path: *const c_char,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    let result = CStr::from_ptr(path)
        .to_str()
        .map_err(|error| error.to_string())
        .and_then(|path| {
            entry_resource(
                archive.0.get_entry_by_path(path),
                !archive.0.header().uses_new_namespaces(),
            )
        });
    return_result(result, error)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_direct_resource(
    archive: &TFKArchive,
    path: *const c_char,
    error: *mut *mut c_char,
) -> *mut TFKDirectResource {
    let result = CStr::from_ptr(path)
        .to_str()
        .map_err(|error| error.to_string())
        .and_then(|path| TFKDirectResource::open(&archive.0, path));
    match result {
        Ok(Some(resource)) => Box::into_raw(Box::new(resource)),
        Ok(None) => ptr::null_mut(),
        Err(message) => {
            write_error(error, message);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_direct_resource_mime(resource: &TFKDirectResource) -> *const c_char {
    resource.mime.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_direct_resource_size(resource: &TFKDirectResource) -> u64 {
    resource.size
}

#[no_mangle]
pub unsafe extern "C" fn tfk_direct_resource_read(
    resource: &TFKDirectResource,
    offset: u64,
    buffer: *mut u8,
    count: usize,
    error: *mut *mut c_char,
) -> bool {
    let result = if count == 0 {
        resource.read(offset, &mut [])
    } else if count > MAX_DIRECT_READ_BYTES || buffer.is_null() {
        Err("The archive resource read buffer is invalid.".into())
    } else {
        resource.read(offset, std::slice::from_raw_parts_mut(buffer, count))
    };
    match result {
        Ok(()) => true,
        Err(message) => {
            write_error(error, message);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_direct_resource_close(resource: *mut TFKDirectResource) {
    drop(Box::from_raw(resource));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_extract_compressed_pdf(
    archive: &TFKArchive,
    path: *const c_char,
    output_fd: i32,
    should_cancel: Option<unsafe extern "C" fn(*mut c_void) -> bool>,
    context: *mut c_void,
    error: *mut *mut c_char,
) -> i32 {
    let check_cancelled = || {
        if should_cancel.is_some_and(|callback| callback(context)) {
            Err(io::Error::other(
                "The compressed PDF extraction was cancelled.",
            ))
        } else {
            Ok(())
        }
    };
    let result = if output_fd < 0 {
        Err("The compressed PDF output file is invalid.".into())
    } else {
        // Duplicate the caller's borrowed descriptor and let File own the duplicate.
        BorrowedFd::borrow_raw(output_fd)
            .try_clone_to_owned()
            .map_err(|error| error.to_string())
            .and_then(|fd| {
                let path = CStr::from_ptr(path)
                    .to_str()
                    .map_err(|error| error.to_string())?;
                extract_compressed_pdf(&archive.0, path, &mut File::from(fd), check_cancelled)
            })
    };
    match result {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(message) => {
            write_error(error, message);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_resolved_path(
    archive: &TFKArchive,
    path: *const c_char,
    error: *mut *mut c_char,
) -> *mut c_char {
    let result = (|| {
        let path = CStr::from_ptr(path)
            .to_str()
            .map_err(|error| error.to_string())?;
        let entry = match archive.0.get_entry_by_path(path) {
            Ok(entry) => entry,
            Err(zimru::Error::EntryNotFound) => return Ok(None),
            Err(error) => return Err(error.to_string()),
        };
        let item = entry.get_item(true).map_err(|error| error.to_string())?;
        item_path(&item, !archive.0.header().uses_new_namespaces()).map(Some)
    })();
    match result {
        Ok(path) => path.map_or(ptr::null_mut(), CString::into_raw),
        Err(message) => {
            write_error(error, message);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_article(
    archive: &TFKArchive,
    index: u32,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    return_article(article_resource(archive, index, None), error)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_article_prefix(
    archive: &TFKArchive,
    index: u32,
    maximum_bytes: usize,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    let maximum_bytes = maximum_bytes.min(MAX_RESOURCE_BYTES as usize);
    return_article(article_resource(archive, index, Some(maximum_bytes)), error)
}

fn article_resource(
    archive: &TFKArchive,
    index: u32,
    maximum_bytes: Option<usize>,
) -> Result<Option<TFKResource>, String> {
    let entry = archive
        .0
        .entry_by_url_index(index)
        .map_err(|error| error.to_string())?;
    let legacy = !archive.0.header().uses_new_namespaces();
    let article_namespace = if !legacy { b'C' } else { b'A' };
    if entry.is_redirect() || entry.namespace() != article_namespace {
        return Ok(None);
    }
    let item = entry.get_item(false).map_err(|error| error.to_string())?;
    if !item.mimetype().starts_with("text/html") {
        return Ok(None);
    }
    match maximum_bytes {
        Some(maximum) => read_item_prefix(item, legacy, maximum),
        None => read_item(item, legacy).map(Some),
    }
}

unsafe fn return_article(
    result: Result<Option<TFKResource>, String>,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    match result {
        Ok(None) => ptr::null_mut(),
        Ok(Some(resource)) => Box::into_raw(Box::new(resource)),
        Err(message) => return_result(Err(message), error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_title_prefix(
    archive: &TFKArchive,
    prefix: *const c_char,
    error: *mut *mut c_char,
) -> *mut TFKTitleMatches {
    let result = (|| {
        let prefix = CStr::from_ptr(prefix)
            .to_str()
            .map_err(|error| error.to_string())?;
        let archive = &archive.0;
        let legacy = !archive.header().uses_new_namespaces();
        let namespace = if legacy { b'A' } else { b'C' };
        let mut matches = Vec::new();
        if prefix.is_empty() || prefix.len() > 512 {
            return Ok(TFKTitleMatches(matches));
        }
        let range = match archive.title_prefix_range(namespace, prefix) {
            Ok(range) => range,
            Err(zimru::Error::EntryNotFound) => return Ok(TFKTitleMatches(matches)),
            Err(error) => return Err(error.to_string()),
        };
        for index in range.take(120) {
            let entry = archive
                .entry_by_title_index(index)
                .map_err(|error| error.to_string())?;
            let Ok(item) = entry.get_item(true) else {
                continue;
            };
            if item.namespace() != namespace || !item.mimetype().starts_with("text/html") {
                continue;
            }
            matches.push(TFKEntryMetadata {
                path: item_path(&item, legacy)?,
                title: CString::new(entry.title()).map_err(|error| error.to_string())?,
            });
            if matches.len() == 30 {
                break;
            }
        }
        Ok(TFKTitleMatches(matches))
    })();
    return_result(result, error)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_title_matches_entry(
    matches: &TFKTitleMatches,
    index: usize,
) -> *const TFKEntryMetadata {
    matches.0.get(index).map_or(ptr::null(), |entry| entry)
}

#[no_mangle]
pub unsafe extern "C" fn tfk_title_matches_close(matches: *mut TFKTitleMatches) {
    drop(Box::from_raw(matches));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_archive_pdf_entry(
    archive: &TFKArchive,
    index: u32,
    error: *mut *mut c_char,
) -> *mut TFKEntryMetadata {
    let result = (|| {
        let entry = archive
            .0
            .entry_by_url_index(index)
            .map_err(|error| error.to_string())?;
        if entry.is_redirect() {
            return Ok(None);
        }
        let item = entry.get_item(false).map_err(|error| error.to_string())?;
        if item.mimetype() != "application/pdf" {
            return Ok(None);
        }
        Ok(Some(TFKEntryMetadata {
            path: item_path(&item, !archive.0.header().uses_new_namespaces())?,
            title: CString::new(item.title()).map_err(|error| error.to_string())?,
        }))
    })();
    match result {
        Ok(None) => ptr::null_mut(),
        Ok(Some(entry)) => Box::into_raw(Box::new(entry)),
        Err(message) => return_result(Err(message), error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tfk_entry_metadata_path(entry: &TFKEntryMetadata) -> *const c_char {
    entry.path.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_entry_metadata_title(entry: &TFKEntryMetadata) -> *const c_char {
    entry.title.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_entry_metadata_close(entry: *mut TFKEntryMetadata) {
    drop(Box::from_raw(entry));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_path(resource: &TFKResource) -> *const c_char {
    resource.path.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_title(resource: &TFKResource) -> *const c_char {
    resource.title.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_mime(resource: &TFKResource) -> *const c_char {
    resource.mime.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_bytes(
    resource: &TFKResource,
    length: &mut usize,
) -> *const u8 {
    let data = match &resource.data {
        ResourceData::Cluster(blob, length) => &blob.data()[..*length],
        ResourceData::DirectPrefix(bytes) => bytes,
    };
    *length = data.len();
    data.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_close(resource: *mut TFKResource) {
    drop(Box::from_raw(resource));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_string_free(value: *mut c_char) {
    drop(CString::from_raw(value));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streams_only_the_selected_large_pdf_and_checks_cluster_tail() {
        let first = 16u32;
        let start = first + 3;
        let end = start + MAX_RESOURCE_BYTES as u32 + 3;
        let last = end + 7;
        let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), 1).unwrap();
        encoder.include_checksum(true).unwrap();
        for offset in [first, start, end, last] {
            encoder.write_all(&offset.to_le_bytes()).unwrap();
        }
        encoder.write_all(b"prePDF").unwrap();
        io::copy(&mut io::repeat(0).take(MAX_RESOURCE_BYTES), &mut encoder).unwrap();
        encoder.write_all(b"trailer").unwrap();
        let mut compressed = encoder.finish().unwrap();
        let mut decoder = zstd::stream::read::Decoder::new(compressed.as_slice()).unwrap();
        decoder.window_log_max(25).unwrap();
        let mut result = Vec::new();
        assert!(extract_pdf_blob(&mut decoder, 4, 1, &mut result, || Ok(())).unwrap());
        assert_eq!(result.len() as u64, MAX_RESOURCE_BYTES + 3);
        assert_eq!(&result[..3], b"PDF");
        assert_eq!(result.last(), Some(&0));

        let checksum = compressed.last_mut().unwrap();
        *checksum ^= 1;
        let mut decoder = zstd::stream::read::Decoder::new(compressed.as_slice()).unwrap();
        assert!(extract_pdf_blob(&mut decoder, 4, 1, &mut io::sink(), || Ok(())).is_err());
    }

    #[test]
    fn compressed_pdf_honors_small_fallback_limits_and_cancellation() {
        let mut small = &[16, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0, b'x'][..];
        assert!(!extract_pdf_blob(&mut small, 8, 0, &mut io::sink(), || Ok(())).unwrap());
        let invalid_end = MAX_COMPRESSED_PDF_CLUSTER_BYTES as u32 + 1;
        let bad = [8u32.to_le_bytes(), invalid_end.to_le_bytes()].concat();
        assert!(extract_pdf_blob(&mut bad.as_slice(), 4, 0, &mut io::sink(), || Ok(())).is_err());
        let cancelled = extract_pdf_blob(
            &mut &[8, 0, 0, 0, 9, 0, 0, 0][..],
            4,
            0,
            &mut io::sink(),
            || Err(io::ErrorKind::Interrupted.into()),
        );
        assert_eq!(cancelled.unwrap_err().kind(), io::ErrorKind::Interrupted);
    }

    #[test]
    fn direct_resource_retains_archive_and_reads_exact_ranges() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../Resources/NearbyPublic/tinfoil-kit-offline-starter_2026-11.zim"
        );
        let archive = Archive::from_file_with_limits(File::open(path).unwrap(), LIMITS).unwrap();
        let item = archive
            .get_entry_by_path("earthquake-safety.html")
            .unwrap()
            .get_item(true)
            .unwrap();
        let expected = item.bytes().unwrap();
        let resource = TFKDirectResource::open(&archive, "earthquake-safety.html")
            .unwrap()
            .unwrap();
        drop(item);
        drop(archive);

        assert_eq!(resource.size, expected.len() as u64);
        assert_eq!(resource.mime.to_str().unwrap(), "text/html");
        let mut bytes = [0; 7];
        resource.read(9, &mut bytes).unwrap();
        assert_eq!(&bytes, &expected[9..16]);
        resource.read(resource.size - 7, &mut bytes).unwrap();
        assert_eq!(&bytes, &expected[expected.len() - 7..]);
        resource.read(resource.size, &mut []).unwrap();
        assert!(resource.read(resource.size, &mut bytes).is_err());
        assert!(resource.read(u64::MAX, &mut bytes).is_err());
        assert!(resource
            .read(0, &mut vec![0; MAX_DIRECT_READ_BYTES + 1])
            .is_err());
    }
}
