# roc-zip

Create and extract ZIP archives in Roc.

- `Zip.create` builds an archive from a list of entries, with a compression option: `None` stores entries as-is, while `Fastest`, `Balanced`, and `Smallest` compress with DEFLATE at increasing effort (falling back to store when compression doesn't help).
- `Zip.extract` reads both store and deflate entries, including archives made by other tools.
- For archives from untrusted sources, `Zip.entries` lists the central directory without inflating anything, and `Zip.extract_entry` inflates one entry within a size limit. An entry that declares more than the limit fails before anything is allocated for it, and a stream that runs past its declared size stops there.
- `Zip.compressed` takes an entry's bytes exactly as stored, so `Zip.add` can copy it into another archive without inflating or recompressing it.
- `Zip.writer`, `Zip.add` and `Zip.finish` write an archive one entry at a time. Each call returns the next chunk, which can go straight to a file. The chunks add up to the bytes `Zip.create` returns.
- `Zip.create_items` (and `Zip.add` with `File` and `Directory`) records a Unix mode and a modification time per entry, and writes explicit directory entries, so an executable extracts as executable with unzip, bsdtar, ditto and Archive Utility, whichever system wrote the archive. `Zip.entries` reads both back.
- `SymbolicLink` items write a link the way `zip -y` does, and `Zip.kind` says whether a listed entry is a file, a directory, a link or something else, whichever system wrote the archive.
- Output is deterministic: entries keep their order, timestamps are zeroed unless you set them, and there are no data descriptors. Repeated paths are refused by the writer and rejected by the reader, since different readers resolve them differently.
- Supports ZIP64, so files and archives larger than 4 GB work.
- Compression comes from [roc-deflate](https://github.com/niclas-ahden/roc-deflate), a pure-Roc DEFLATE implementation. Use that package directly if you need raw DEFLATE streams (gzip, PNG, etc.) without the ZIP container.

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
    zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
}

import pf.Stdout
import pf.OsStr
import zip.Zip

main! = |args| {
    # Archives the text you pass on the command line as the lyrics, or this
    # line if you pass none
    lyrics = match args.get(0) {
        Ok(arg) => OsStr.display(arg).to_utf8()
        Err(_) => "Bought a tarantula from a Swedish guy, he helped me out in Stockholm with a DUI".to_utf8()
    }

    entries = [
        { path: "irish/artists.txt", content: "Rubberbandits".to_utf8() },
        { path: "irish/songs.txt", content: "Dad's Best Friend".to_utf8() },
        { path: "irish/lyrics.txt", content: lyrics },
        { path: "links.txt", content: "https://www.youtube.com/watch?v=iYgPznBrjiA".to_utf8() },
    ]

    match Zip.create(entries, Balanced) {
        Ok(archive) => Stdout.line!("Created a ${archive.len().to_str()} byte archive")?
        Err(EmptyPath(_path)) => Stdout.line!("Path was empty")?
        Err(PathTooLong(_path)) => Stdout.line!("Path exceeds 65535 bytes")?
        Err(DuplicatePath(_path)) => Stdout.line!("Two entries share a path")?
    }

    Ok({})
}
```

See [examples](examples/) for a runnable program.

## Unix modes and times

`Zip.create` records no permissions, so extracting tools fall back to their defaults and a program loses its execute bit. To keep it, give each entry a mode with `Zip.create_items`:

```roc
# Seconds since the Unix epoch, for example from SOURCE_DATE_EPOCH
modified = Zip.dos_time(1_700_000_000)

Zip.create_items([
    Directory({ path: "MyApp.app/Contents/MacOS/", mode: Unix(0o755), modified }),
    File({ path: "MyApp.app/Contents/MacOS/MyApp", content: program, mode: Unix(0o755), modified }),
    File({ path: "MyApp.app/Contents/Info.plist", content: plist, mode: Unix(0o644), modified }),
], Balanced)
```

`mode` and `modified` are optional. Left out, an entry is written exactly as `Zip.create` writes it, with no mode and the time 1980-01-01 00:00. A list of items built in a lambda needs an annotation, `items : List(Zip.Item)`, for those defaults to apply. `Zip.entries` reports each entry's `mode` (`Unix(st_mode)` when the archive was made on Unix, otherwise `NotRecorded`) and `modified`.

A `SymbolicLink` item is a link whose content is its target, which unzip, bsdtar and ditto restore as a link:

```roc
SymbolicLink({ path: "MyApp.app/Contents/Current", target: "MacOS/MyApp" })
```

## Reading untrusted archives

A small archive can declare, or inflate to, gigabytes. List it first, and extract each entry within a limit:

```roc
read_parts : List(U8) -> Try(List({ path : Str, content : List(U8) }), _)
read_parts = |bytes| {
    index = Zip.entries(bytes)?
    var $parts = []
    for entry in index {
        content = Zip.extract_entry(bytes, entry, { max_bytes: 16_777_216 })?
        $parts = $parts.append({ path: entry.path, content })
    }
    Ok($parts)
}
```

To write the entries to disk yourself, check each path with `Zip.is_safe_path` and ask `Zip.kind` what the entry is. It follows the entry's Unix mode when there is one and its name otherwise, as unzip and bsdtar do, so it needs no knowledge of which system wrote the archive. Refuse what you do not create yourself:

```roc
for entry in Zip.entries(bytes)? {
    match Zip.kind(entry) {
        File => # write Zip.extract_entry(bytes, entry, limits)? to entry.path
        Directory => # create entry.path
        SymbolicLink | Other => return Err(Unsupported(entry.path))
    }
}
```

`Other` covers devices, FIFOs and sockets, and entries whose mode and name contradict each other in ways readers resolve differently.

Listing holds memory in proportion to the central directory, not to the sizes the entries declare. Extracting holds at most the decoder's tables and the entry's declared size. The [fuzz targets](fuzz/) check both bounds, along with the rest of the API, against arbitrary and corrupted archives.

## Choosing a compression level

`Zip.create` takes one of four compression options: `None` skips compression entirely (fastest possible, no size reduction), and the other three (`Fastest`, `Balanced`, `Smallest`) trade speed for size. Here's how they compare to `gzip` on the [Silesia corpus](http://mattmahoney.net/dc/silesia.html) (times are only meant to give an indication in relation to one another):

| Level      | Compressed size  | Ratio | Time   |
| ---------- | ---------------- | ----- | ------ |
| `Fastest`  | 85,524,903 bytes | 40.4% | ~4.7 s |
| `Balanced` | 78,420,875 bytes | 37.0% | ~6.9 s |
| `Smallest` | 76,929,989 bytes | 36.3% | ~15 s  |
| gzip -1    | 77,366,708 bytes | 36.5% | ~1.3 s |
| gzip -6    | 68,227,965 bytes | 32.2% | ~4.3 s |
| gzip -9    | 67,631,990 bytes | 31.9% | ~10 s  |

Speed and compression will improve as [roc-deflate](https://github.com/niclas-ahden/roc-deflate) and the Roc compiler matures. There's lots of headroom for improvement, so see this as a starting point 👍
