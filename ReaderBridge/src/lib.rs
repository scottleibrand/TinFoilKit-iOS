use std::ffi::{c_char, CStr, CString};
use std::fs::File;
use std::ptr;
use zimru::{Archive, ArchiveLimits, Blob, ClusterReadLimits, Entry, Item};

const MIB: u64 = 1024 * 1024;
const MAX_RESOURCE_BYTES: u64 = 32 * MIB;
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

pub struct TFKResource {
    path: CString,
    title: CString,
    mime: CString,
    data: Blob,
}

fn read_item(item: Item, legacy: bool) -> Result<TFKResource, String> {
    if item.size().map_err(|error| error.to_string())? > MAX_RESOURCE_BYTES {
        return Err("This archive resource exceeds the 32 MiB reader limit.".into());
    }
    let path = if legacy {
        format!("{}/{}", char::from(item.namespace()), item.path())
    } else {
        item.path().to_owned()
    };
    Ok(TFKResource {
        path: CString::new(path).map_err(|error| error.to_string())?,
        title: CString::new(item.title()).map_err(|error| error.to_string())?,
        mime: CString::new(item.mimetype()).map_err(|error| error.to_string())?,
        data: item.get_data().map_err(|error| error.to_string())?,
    })
}

fn entry_resource(entry: zimru::Result<Entry>, legacy: bool) -> Result<TFKResource, String> {
    let entry = entry.map_err(|error| error.to_string())?;
    read_item(
        entry.get_item(true).map_err(|error| error.to_string())?,
        legacy,
    )
}

unsafe fn return_result<T>(result: Result<T, String>, error: *mut *mut c_char) -> *mut T {
    match result {
        Ok(value) => Box::into_raw(Box::new(value)),
        Err(message) => {
            if !error.is_null() {
                *error = CString::new(message)
                    .unwrap_or_else(|_| CString::new("Could not read the ZIM archive.").unwrap())
                    .into_raw();
            }
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
pub unsafe extern "C" fn tfk_archive_article(
    archive: &TFKArchive,
    index: u32,
    error: *mut *mut c_char,
) -> *mut TFKResource {
    let result = (|| {
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
        read_item(item, legacy).map(Some)
    })();
    match result {
        Ok(None) => ptr::null_mut(),
        Ok(Some(resource)) => Box::into_raw(Box::new(resource)),
        Err(message) => return_result(Err(message), error),
    }
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
    *length = resource.data.size();
    resource.data.data().as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tfk_resource_close(resource: *mut TFKResource) {
    drop(Box::from_raw(resource));
}

#[no_mangle]
pub unsafe extern "C" fn tfk_string_free(value: *mut c_char) {
    drop(CString::from_raw(value));
}
