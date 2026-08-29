//! Rustler NIF wrapper around the `feoxdb` Rust crate
//! (https://github.com/mehrantsi/feoxdb), exposing just enough surface for
//! `Restdis.Cache.Storage.FeoxDB` to implement the `Restdis.Cache.Storage`
//! behaviour: open/close, get/put/delete, clear and a full-scan select.
//!
//! NOTE: this crate has not been compiled in the environment it was
//! authored in (no outbound network access to crates.io to fetch the
//! `feoxdb` and `rustler` dependencies), so it has not been build- or
//! test-verified against the real `feoxdb` API. Function names and
//! signatures below are based on the crate's published README; check them
//! against the installed `feoxdb` version before relying on this in
//! production, and adjust as needed once it compiles.

use feoxdb::FeoxStore;
use rustler::{Binary, Env, NifResult, OwnedBinary, ResourceArc};
use std::sync::Mutex;

pub struct StoreResource(Mutex<FeoxStore>);

impl rustler::Resource for StoreResource {}

fn to_owned(bin: &[u8]) -> OwnedBinary {
    let mut owned = OwnedBinary::new(bin.len()).expect("allocate binary");
    owned.as_mut_slice().copy_from_slice(bin);
    owned
}

#[rustler::nif]
fn open(path: Option<String>) -> NifResult<ResourceArc<StoreResource>> {
    let store = match path {
        Some(path) => FeoxStore::new(Some(path.as_str())),
        None => FeoxStore::new(None),
    }
    .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(StoreResource(Mutex::new(store))))
}

#[rustler::nif]
fn put<'a>(resource: ResourceArc<StoreResource>, key: Binary<'a>, value: Binary<'a>) -> NifResult<()> {
    let store = resource.0.lock().expect("store lock poisoned");
    store
        .insert(key.as_slice(), value.as_slice())
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}

#[rustler::nif]
fn get<'a>(env: Env<'a>, resource: ResourceArc<StoreResource>, key: Binary<'a>) -> NifResult<Option<Binary<'a>>> {
    let store = resource.0.lock().expect("store lock poisoned");

    match store.get(key.as_slice()) {
        Ok(Some(value)) => Ok(Some(to_owned(&value).release(env))),
        Ok(None) => Ok(None),
        Err(err) => Err(rustler::Error::Term(Box::new(err.to_string()))),
    }
}

#[rustler::nif]
fn delete(resource: ResourceArc<StoreResource>, key: Binary) -> NifResult<bool> {
    let store = resource.0.lock().expect("store lock poisoned");
    store
        .delete(key.as_slice())
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}

#[rustler::nif]
fn clear(resource: ResourceArc<StoreResource>) -> NifResult<()> {
    let store = resource.0.lock().expect("store lock poisoned");

    for (key, _value) in store
        .range_query(None, None, None)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?
    {
        let _ = store.delete(&key);
    }

    Ok(())
}

#[rustler::nif]
fn select_all<'a>(env: Env<'a>, resource: ResourceArc<StoreResource>) -> NifResult<Vec<(Binary<'a>, Binary<'a>)>> {
    let store = resource.0.lock().expect("store lock poisoned");

    let entries = store
        .range_query(None, None, None)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?
        .into_iter()
        .map(|(key, value)| (to_owned(&key).release(env), to_owned(&value).release(env)))
        .collect();

    Ok(entries)
}

#[rustler::nif]
fn flush(resource: ResourceArc<StoreResource>) -> NifResult<()> {
    let store = resource.0.lock().expect("store lock poisoned");
    store
        .flush()
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}

fn on_load(env: Env, _info: rustler::Term) -> bool {
    env.register::<StoreResource>().is_ok()
}

rustler::init!("Elixir.Restdis.Cache.Storage.FeoxDB.Native", load = on_load);
