## Forward interop: real ZIP tools read the archives roc-zip writes.
##
## The package's own `expect` blocks round-trip Zip.create through Zip.extract,
## which cannot catch a shared misreading of the spec: both sides would have to
## agree on the same mistake for the test to still pass. The fixture archives in
## Zip.roc cover the other direction (real tools -> us). This harness closes the
## loop by handing archives we build to unzip, bsdtar and 7z and comparing the
## bytes they hand back against the originals.
##
## Every entry is compared byte for byte rather than by exit code. `unzip -p`
## exits 0 and prints nothing when it cannot match a name, so an exit-code check
## alone would pass silently on an archive no reader could actually read.
##
## It also runs the other way for symbolic links: Info-ZIP's `zip -y` and
## bsdtar archive a tree with links, and `Zip.kind` must agree with zipinfo on
## every entry. The tools come from the flake dev shell:
##
##     nix develop -c ./tests.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	zip: "../package/main.roc",
}

import pf.Stdout
import pf.Cmd
import pf.Path
import pf.Env
import pf.IOErr
import pf.OsStr
import pf.System
import zip.Zip

main! = |args| {
	# `args.len()` keeps the entries runtime-derived. With fully literal entries
	# the compiler evaluates Zip.create at build time, which defeats the point of
	# handing a freshly built archive to another program. The arguments exclude
	# the program name, so `n` is 1 with none, and the archives stay identical
	# across runs.
	n = args.len() + 1
	tmp = Env.temp_dir!()

	Stdout.line!("== forward: real tools read the archives we write")?
	check!(tmp, n, "store", None)?
	check!(tmp, n, "fastest", Fastest)?
	check!(tmp, n, "balanced", Balanced)?
	check!(tmp, n, "smallest", Smallest)?

	Stdout.line!("== forward: real tools read entries copied as stored")?
	check_copy!(tmp, n)?

	Stdout.line!("== forward: real tools read a ZIP64 end of central directory")?
	check_zip64!(tmp, n)?

	Stdout.line!("== forward: real tools restore Unix modes and times")?
	check_modes!(tmp, n)?

	target = System.target!()
	match target.os() {
		# Windows makes no symbolic links without privileges.
		Windows(_) => {}
		_ => {
			Stdout.line!("== forward: real tools restore symbolic links")?
			check_links!(tmp, n)?

			Stdout.line!("== back: Zip.kind agrees with zipinfo on what zip and bsdtar write")?
			check_kinds!(tmp, n)?
		}
	}

	Stdout.line!("All forward interop checks passed")?
	Ok({})
}

# Copy every entry of a compressed archive into a new one through
# Zip.compressed and Copied, the way a reader passes parts it does not model
# through unchanged, then make every reader prove the copy is intact.
check_copy! : Path.Path, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_copy! = |tmp, n| {
	entries = sample_entries(n)
	source = Zip.create(entries, Balanced) ?? []
	index = Zip.entries(source) ?? []
	var $writer = Zip.writer({ compression: None })
	var $copy = []
	for entry in index {
		added = match Zip.compressed(source, entry) {
			Ok(stored) => Zip.add($writer, Copied(stored)).map_err(|_| {})
			Err(_) => Err({})
		}
		match added {
			Ok({ writer, chunk }) => {
				$writer = writer
				$copy = $copy.concat(chunk)
			}
			Err(_) => {
				Stdout.line!("  copy: could not copy ${entry.path}")?
				Err(Exit(1))?
			}
		}
	}
	archive = $copy.concat(Zip.finish($writer))

	zip_path = tmp.join("roc_zip_harness_copy.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))
	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], "copy")?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], "copy")?
	verify_from!(zip_os, entries, "copy", 0)?
	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  copy: ${index.len().to_str()} entries, ${archive.len().to_str()} bytes, unzip + bsdtar + 7z all agree")
}

# The items of a small app bundle, each with its mode, and every file and
# directory a mode string `ls -l` prints for it. A program keeps its execute
# bits, and the modes beside 0755 and 0644 show the bits are not a default.
mode_items : U64 -> List({ item : Zip.Item, content : List(U8), ls : Str })
mode_items = |n| {
	modified = Zip.dos_time(1_699_999_999 + n)
	program = repeated_text(20 * n)
	[
		{ item: Directory({ path: "My.app", mode: Unix(0o755), modified }), content: [], ls: "drwxr-xr-x" },
		{ item: Directory({ path: "My.app/Contents/", mode: Unix(0o755), modified }), content: [], ls: "drwxr-xr-x" },
		{ item: Directory({ path: "My.app/Contents/MacOS/", mode: Unix(0o755), modified }), content: [], ls: "drwxr-xr-x" },
		{ item: File({ path: "My.app/Contents/MacOS/My", content: program, mode: Unix(0o755), modified }), content: program, ls: "-rwxr-xr-x" },
		{ item: File({ path: "My.app/Contents/Info.plist", content: "<plist/>".to_utf8(), mode: Unix(0o644), modified }), content: "<plist/>".to_utf8(), ls: "-rw-r--r--" },
		{ item: Directory({ path: "My.app/Contents/Private/", mode: Unix(0o700), modified }), content: [], ls: "drwx------" },
		{ item: File({ path: "My.app/Contents/Private/key", content: [1, 2, 3], mode: Unix(0o600), modified }), content: [1, 2, 3], ls: "-rw-------" },
	]
}

# An archive of items with Unix modes and a time. unzip -Z must list each
# entry as made on Unix with its mode and the time, and unzip, bsdtar and
# (on macOS) ditto must restore each mode when they extract it.
check_modes! : Path.Path, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_modes! = |tmp, n| {
	listed = mode_items(n)
	items = listed.map(|entry| entry.item)
	archive = Zip.create_items(items, Balanced) ?? []
	if Zip.create_items(items, Balanced) != Ok(archive) or archive.is_empty() {
		Stdout.line!("  modes: create_items failed or was not deterministic")?
		Err(Exit(1))?
	}
	index = Zip.entries(archive) ?? []
	paths = index.map(|entry| entry.path)

	zip_path = tmp.join("roc_zip_harness_modes.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))
	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], "modes")?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], "modes")?

	# zipinfo's short listing, one line per entry: mode, version, host,
	# sizes, type, method, then (with -T) the time as yyyymmdd.hhmmss, and
	# the name.
	listing = stdout_of!("unzip", [OsStr.from_str("-Z"), OsStr.from_str("-T"), zip_os], "modes")?
	lines = listing.split_on("\n").keep_if(|line| line.starts_with("d") or line.starts_with("-"))
	expected = listed.map_with_index(|entry, i| "${entry.ls} unx ${paths.get(i) ?? ""}")
	got = lines.map(
		|line| {
			fields = line.split_on(" ").keep_if(|field| !field.is_empty())
			"${fields.get(0) ?? ""} ${fields.get(2) ?? ""} ${fields.get(fields.len() - 1) ?? ""}"
		},
	)
	if got != expected {
		Stdout.line!("  modes: unzip -Z listed\n${listing}")?
		Err(Exit(1))?
	}
	stamp = dos_stamp(Zip.dos_time(1_699_999_999 + n))
	if !lines.all(|line| line.contains(" ${stamp} ")) {
		Stdout.line!("  modes: unzip -Z did not show the time ${stamp}:\n${listing}")?
		Err(Exit(1))?
	}

	target = System.target!()
	extractors = match target.os() {
		MacOS(_) => ["unzip", "bsdtar", "ditto"]
		Linux(_) => ["unzip", "bsdtar"]
		# Windows has no Unix modes to restore.
		Windows(_) => []
	}
	for extractor in extractors {
		into = tmp.join("roc_zip_harness_modes_${extractor}")
		match Path.delete_all!(into) {
			_ => {}
		}
		Path.create_all!(into) ? |_| Exit(1)
		into_os = OsStr.from_raw(Path.to_raw(into))
		arguments = match extractor {
			"unzip" => [OsStr.from_str("-q"), zip_os, OsStr.from_str("-d"), into_os]
			"bsdtar" => [OsStr.from_str("-xf"), zip_os, OsStr.from_str("-C"), into_os]
			_ => [OsStr.from_str("-x"), OsStr.from_str("-k"), zip_os, into_os]
		}
		expect_ok!(extractor, arguments, "modes")?
		for entry in listed.map_with_index(|entry, i| { path: paths.get(i) ?? "", ls: entry.ls, content: entry.content }) {
			on_disk = into.join(entry.path.drop_suffix("/"))
			mode = ls_mode!(on_disk, "modes")?
			if mode != entry.ls {
				Stdout.line!("  modes: ${extractor} gave ${entry.path} ${mode}, not ${entry.ls}")?
				Err(Exit(1))?
			}
			if !entry.path.ends_with("/") {
				bytes = Path.read_bytes!(on_disk) ? |_| Exit(1)
				if bytes != entry.content {
					Stdout.line!("  modes: ${extractor} MISMATCH on ${entry.path}")?
					Err(Exit(1))?
				}
			}
		}
		Path.delete_all!(into) ? |_| Exit(1)
	}

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  modes: ${index.len().to_str()} entries, unzip -Z lists every mode and the time, ${Str.join_with(extractors, " + ")} restore every mode")
}

# Links beside the file and directory they point into, one dangling and one
# whose target is long enough to be deflated.
link_items : U64 -> List({ item : Zip.Item, path : Str, target : Str })
link_items = |n| {
	long = Str.repeat("../", 100 + n).concat("Links/target.txt")
	[
		{ item: Directory({ path: "Links/", mode: Unix(0o755) }), path: "Links/", target: "" },
		{ item: File({ path: "Links/target.txt", content: "pointed at".to_utf8(), mode: Unix(0o644) }), path: "Links/target.txt", target: "" },
		{ item: SymbolicLink({ path: "Links/to-target", target: "target.txt" }), path: "Links/to-target", target: "target.txt" },
		{ item: SymbolicLink({ path: "Links/dangling", target: "../missing" }), path: "Links/dangling", target: "../missing" },
		{ item: SymbolicLink({ path: "Links/long", target: long }), path: "Links/long", target: long },
	]
}

# An archive with symbolic links. unzip -Z must list each link as one made on
# Unix, `unzip -p` must print its target, and unzip, bsdtar and (on macOS)
# ditto must make each one a link to its target when they extract it.
check_links! : Path.Path, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_links! = |tmp, n| {
	listed = link_items(n)
	items = listed.map(|entry| entry.item)
	archive = Zip.create_items(items, Balanced) ?? []
	if Zip.create_items(items, Balanced) != Ok(archive) or archive.is_empty() {
		Stdout.line!("  links: create_items failed or was not deterministic")?
		Err(Exit(1))?
	}
	links = listed.keep_if(|entry| !entry.target.is_empty())
	deflated = (Zip.entries(archive) ?? []).keep_if(|entry| entry.method == Deflated).map(|entry| entry.path)
	if !deflated.contains("Links/long") {
		Stdout.line!("  links: the long target was not deflated, so a deflated link goes untested")?
		Err(Exit(1))?
	}

	zip_path = tmp.join("roc_zip_harness_links.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))
	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], "links")?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], "links")?
	_ = check_zipinfo_kinds!(archive, zip_os, "links")?
	for link in links {
		expect_bytes!("unzip", [OsStr.from_str("-p"), zip_os, OsStr.from_str(link.path)], { path: link.path, content: link.target.to_utf8() }, "links")?
	}

	target = System.target!()
	extractors = match target.os() {
		MacOS(_) => ["unzip", "bsdtar", "ditto"]
		_ => ["unzip", "bsdtar"]
	}
	for extractor in extractors {
		into = tmp.join("roc_zip_harness_links_${extractor}")
		match Path.delete_all!(into) {
			_ => {}
		}
		Path.create_all!(into) ? |_| Exit(1)
		into_os = OsStr.from_raw(Path.to_raw(into))
		arguments = match extractor {
			"unzip" => [OsStr.from_str("-q"), zip_os, OsStr.from_str("-d"), into_os]
			"bsdtar" => [OsStr.from_str("-xf"), zip_os, OsStr.from_str("-C"), into_os]
			_ => [OsStr.from_str("-x"), OsStr.from_str("-k"), zip_os, into_os]
		}
		expect_ok!(extractor, arguments, "links")?
		for link in links {
			on_disk = into.join(link.path)
			mode = ls_mode!(on_disk, "links")?
			made = stdout_of!("readlink", [OsStr.from_raw(Path.to_raw(on_disk))], "links")?
			if !mode.starts_with("l") or made != "${link.target}\n" {
				Stdout.line!("  links: ${extractor} made ${link.path} ${mode} to ${made}, not a link to ${link.target}")?
				Err(Exit(1))?
			}
		}
		pointed = Path.read_bytes!(into.join("Links/to-target")) ? |_| Exit(1)
		if pointed != "pointed at".to_utf8() {
			Stdout.line!("  links: ${extractor}'s Links/to-target does not reach Links/target.txt")?
			Err(Exit(1))?
		}
		Path.delete_all!(into) ? |_| Exit(1)
	}

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  links: ${links.len().to_str()} links, unzip -Z lists each, unzip -p prints each target, ${Str.join_with(extractors, " + ")} restore each")
}

# The other direction: a tree with a file, a program, an empty file, nested
# and empty directories and two links, archived by Info-ZIP's `zip -y` and by
# bsdtar. Zip.kind must say of every entry what zipinfo's mode string says,
# and every file must extract to the bytes `unzip -p` prints.
check_kinds! : Path.Path, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_kinds! = |tmp, n| {
	root = tmp.join("roc_zip_harness_kinds")
	match Path.delete_all!(root) {
		_ => {}
	}
	tree = root.join("tree")
	Path.create_all!(tree.join("sub/deeper")) ? |_| Exit(1)
	Path.create_all!(tree.join("empty")) ? |_| Exit(1)
	Path.write_bytes!(tree.join("a.txt"), repeated_text(n)) ? |_| Exit(1)
	Path.write_bytes!(tree.join("run.sh"), "#!/bin/sh\necho hi\n".to_utf8()) ? |_| Exit(1)
	Path.write_bytes!(tree.join("sub/deeper/zero"), []) ? |_| Exit(1)
	in_tree = |relative| OsStr.from_raw(Path.to_raw(tree.join(relative)))
	expect_ok!("chmod", [OsStr.from_str("755"), in_tree("run.sh")], "kinds")?
	expect_ok!("ln", [OsStr.from_str("-s"), OsStr.from_str("a.txt"), in_tree("link")], "kinds")?
	expect_ok!("ln", [OsStr.from_str("-s"), OsStr.from_str("../nowhere"), in_tree("sub/dangling")], "kinds")?

	writers = [
		{ name: "zip -y", archive: "infozip.zip", program: "zip", arguments: ["-X", "-q", "-r", "-y"] },
		{ name: "bsdtar", archive: "bsdtar.zip", program: "bsdtar", arguments: ["--format", "zip", "-cf"] },
	]
	for writer in writers {
		zip_path = root.join(writer.archive)
		zip_os = OsStr.from_raw(Path.to_raw(zip_path))
		# Both are run from the root so the entries are named tree/...
		made = match Cmd.new(OsStr.from_str(writer.program)).args(writer.arguments.map(OsStr.from_str).concat([zip_os, OsStr.from_str("tree")])).cwd(root).run!() {
			Ok(output) => output.status == Exited(0)
			Err(_) => Bool.False
		}
		if !made {
			Stdout.line!("  kinds: ${writer.name} could not archive the tree")?
			Err(Exit(1))?
		}
		archive = Path.read_bytes!(zip_path) ? |_| Exit(1)
		kinds = check_zipinfo_kinds!(archive, zip_os, writer.name)?
		for want in [("tree/link", SymbolicLink), ("tree/sub/dangling", SymbolicLink), ("tree/empty/", Directory), ("tree/run.sh", File)] {
			(path, kind) = want
			if !kinds.contains((path, kind)) {
				Stdout.line!("  kinds: ${writer.name}'s archive has no ${path} of the kind expected")?
				Err(Exit(1))?
			}
		}
		for entry in Zip.entries(archive) ?? [] {
			if Zip.kind(entry) == File {
				content = Zip.extract_entry(archive, entry, {}) ?? []
				expect_bytes!("unzip", [OsStr.from_str("-p"), zip_os, OsStr.from_str(entry.path)], { path: entry.path, content }, writer.name)?
			}
		}
	}
	Path.delete_all!(root) ? |_| Exit(1)
	Stdout.line!("  kinds: zip -y and bsdtar archives, Zip.kind agrees with zipinfo on every entry and every file matches unzip -p")
}

# List an archive with zipinfo, and require Zip.kind to say of each entry
# what the first character of its mode string does: `-` a file, `d` a
# directory and `l` a link. Returns each path with its kind.
check_zipinfo_kinds! : List(U8), OsStr, Str => Try(List((Str, Zip.EntryKind)), [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_zipinfo_kinds! = |archive, zip_os, name| {
	index = match Zip.entries(archive) {
		Ok(listed) => listed
		Err(err) => {
			Stdout.line!("  ${name}: Zip.entries failed: ${Str.inspect(err)}")?
			Err(Exit(1))?
		}
	}
	listing = stdout_of!("unzip", [OsStr.from_str("-Z"), OsStr.from_str("-1"), zip_os], name)?
	modes = stdout_of!("unzip", [OsStr.from_str("-Z"), OsStr.from_str("-s"), zip_os], name)?
	names = listing.split_on("\n").keep_if(|line| !line.is_empty())
	letters = modes.split_on("\n").keep_if(|line| line.starts_with("-") or line.starts_with("d") or line.starts_with("l")).map(|line| Str.from_utf8_lossy(line.to_utf8().take_first(1)))
	if names != index.map(|entry| entry.path) or letters.len() != index.len() {
		Stdout.line!("  ${name}: zipinfo listed\n${modes}")?
		Err(Exit(1))?
	}
	kinds = index.map(|entry| (entry.path, Zip.kind(entry)))
	for (i, entry) in index.map_with_index(|entry, i| (i, entry)) {
		expected = match letters.get(i) ?? "" {
			"-" => File
			"d" => Directory
			"l" => SymbolicLink
			_ => Other
		}
		if Zip.kind(entry) != expected {
			Stdout.line!("  ${name}: zipinfo says ${entry.path} is ${letters.get(i) ?? ""}, Zip.kind says ${Str.inspect(Zip.kind(entry))}")?
			Err(Exit(1))?
		}
	}
	Ok(kinds)
}

# A DOS time as zipinfo's -T prints it, yyyymmdd.hhmmss.
dos_stamp : Zip.DosTime -> Str
dos_stamp = |{ date, time }| {
	two = |value| if value < 10 { "0${value.to_str()}" } else { value.to_str() }
	year = (date.shr_zf_wrap(9) + 1980).to_str()
	month = two(date.shr_zf_wrap(5).bitwise_and(0xF))
	day = two(date.bitwise_and(0x1F))
	hour = two(time.shr_zf_wrap(11))
	minute = two(time.shr_zf_wrap(5).bitwise_and(0x3F))
	second = two(time.bitwise_and(0x1F) * 2)
	"${year}${month}${day}.${hour}${minute}${second}"
}

# The mode string `ls -ld` prints for a path, without the marker macOS
# appends for extended attributes or an ACL.
ls_mode! : Path.Path, Str => Try(Str, [Exit(I32), Interrupted, StdoutErr(IOErr)])
ls_mode! = |path, name| {
	line = stdout_of!("ls", [OsStr.from_str("-ld"), OsStr.from_raw(Path.to_raw(path))], name)?
	mode = line.split_on(" ").get(0) ?? ""
	Ok(Str.from_utf8_lossy(mode.to_utf8().take_first(10)))
}

# Run a command and return its stdout, failing the script on a nonzero exit.
stdout_of! : Str, List(OsStr), Str => Try(Str, [Exit(I32), Interrupted, StdoutErr(IOErr)])
stdout_of! = |program, arguments, name| {
	output = match Cmd.new(OsStr.from_str(program)).args(arguments).run!() {
		Ok(res) => res
		Err(_) => {
			Stdout.line!("  ${name}: could not run ${program}")?
			Err(Exit(1))?
		}
	}
	match output.status {
		Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes))
		status => {
			Stdout.line!("  ${name}: ${program} ${Str.inspect(status)}: ${output.stderr_utf8_lossy()}")?
			Err(Exit(1))
		}
	}
}

# More than 65535 entries overflows the classic 16-bit entry count, so the
# archive gains a ZIP64 end of central directory record and locator and the
# classic record carries sentinels. Zip.roc's own tests only round-trip that
# through Zip.extract, which shares this writer's assumptions, so prove real
# readers accept it too.
check_zip64! : Path.Path, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_zip64! = |tmp, n| {
	total = 65535 + n
	entries = many_entries(0, total, List.with_capacity(total))
	archive = match Zip.create(entries, None) {
		Ok(bytes) => bytes
		Err(_) => {
			Stdout.line!("  zip64: Zip.create failed")?
			Err(Exit(1))?
		}
	}

	zip_path = tmp.join("roc_zip_harness_zip64.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))

	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], "zip64")?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], "zip64")?

	# Spot-check the ends rather than all 65536 entries: three readers times
	# every entry would be a quarter of a million subprocesses.
	first = entries.get(0) ?? { path: "", content: [] }
	last = entries.get(total - 1) ?? { path: "", content: [] }
	verify_entry!(zip_os, first, "zip64")?
	verify_entry!(zip_os, last, "zip64")?

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  zip64: ${total.to_str()} entries, ${archive.len().to_str()} bytes, unzip + bsdtar + 7z all agree")
}

# Distinct names and contents, so a reader that loses or misorders an entry
# cannot pass by accident.
many_entries : U64, U64, List({ path : Str, content : List(U8) }) -> List({ path : Str, content : List(U8) })
many_entries = |index, total, acc|
	if index >= total {
		acc
	} else {
		many_entries(index + 1, total, acc.append({ path: "e${index.to_str()}.txt", content: index.to_str().to_utf8() }))
	}

# Build one archive at the given compression, then make every reader prove it
# can both verify the container and reproduce each entry's bytes.
check! : Path.Path, U64, Str, [None, Fastest, Balanced, Smallest] => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check! = |tmp, n, name, level| {
	entries = sample_entries(n)
	archive = match Zip.create(entries, level) {
		Ok(bytes) => bytes
		Err(EmptyPath(path)) => {
			Stdout.line!("  ${name}: Zip.create rejected an empty path: ${path}")?
			Err(Exit(1))?
		}
		Err(PathTooLong(path)) => {
			Stdout.line!("  ${name}: Zip.create rejected a long path: ${path}")?
			Err(Exit(1))?
		}
		Err(DuplicatePath(path)) => {
			Stdout.line!("  ${name}: Zip.create rejected a repeated path: ${path}")?
			Err(Exit(1))?
		}
	}

	zip_path = tmp.join("roc_zip_harness_${name}.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))

	# Container-level verification: both readers walk every entry and check its
	# CRC against the stored value.
	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], name)?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], name)?

	verify_from!(zip_os, entries, name, 0)?

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  ${name}: ${archive.len().to_str()} bytes, unzip + bsdtar + 7z all agree")
}

# The archive every reader is asked to read back. Covers nested directories, an
# empty entry, non-text bytes, a UTF-8 name (general purpose bit 11) and enough
# repetitive text that compression actually engages instead of falling back to
# store.
sample_entries : U64 -> List({ path : Str, content : List(U8) })
sample_entries = |n| [
	{ path: "hello.txt", content: "Hello, World!".to_utf8() },
	{ path: "docs/readme.md", content: "# Readme".to_utf8() },
	{ path: "deep/nested/path/file.txt", content: "deep".to_utf8() },
	{ path: "empty.txt", content: [] },
	{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] },
	{ path: "utf8/räksmörgås.txt", content: "UTF-8 filename".to_utf8() },
	{ path: "big.txt", content: repeated_text(200 * n) },
]

# Check one entry against every reader that can address it.
verify_entry! : OsStr, { path : Str, content : List(U8) }, Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
verify_entry! = |zip_os, entry, name| {
	path_os = OsStr.from_str(entry.path)

	# Info-ZIP 3.00 predates UTF-8 name support and cannot match a non-ASCII
	# name on the command line (it reports "filename not matched" and still
	# exits 0), so bsdtar and 7z carry that entry.
	_skip_non_ascii = if is_ascii(entry.path) {
		expect_bytes!("unzip", [OsStr.from_str("-p"), zip_os, path_os], entry, name)?
	} else {
		{}
	}

	# libarchive on macOS normalizes entry names to decomposed Unicode, so the
	# precomposed name from the command line never matches there. A glob in
	# place of the non-ASCII characters matches under either form, and bsdtar
	# still exits 1 when nothing matches.
	expect_bytes!("bsdtar", [OsStr.from_str("-xOf"), zip_os, OsStr.from_str(bsdtar_pattern(entry.path))], entry, name)?
	expect_bytes!("7z", [OsStr.from_str("e"), OsStr.from_str("-so"), zip_os, path_os], entry, name)
}

verify_from! : OsStr, List({ path : Str, content : List(U8) }), Str, U64 => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
verify_from! = |zip_os, entries, name, index|
	if index >= entries.len() {
		Ok({})
	} else {
		entry = entries.get(index) ?? { path: "", content: [] }
		verify_entry!(zip_os, entry, name)?
		verify_from!(zip_os, entries, name, index + 1)
	}

# Run a reader and require its stdout to equal the entry's original content.
expect_bytes! : Str, List(OsStr), { path : Str, content : List(U8) }, Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
expect_bytes! = |program, arguments, entry, name| {
	output = match Cmd.new(OsStr.from_str(program)).args(arguments).run!() {
		Ok(res) => res
		Err(_) => {
			Stdout.line!("  ${name}: could not run ${program}")?
			Err(Exit(1))?
		}
	}
	got = match output.status {
		Exited(0) => output.stdout_bytes
		status => {
			Stdout.line!("  ${name}: ${program} ${Str.inspect(status)} on ${entry.path}: ${output.stderr_utf8_lossy()}")?
			Err(Exit(1))?
		}
	}

	if got == entry.content {
		Ok({})
	} else {
		Stdout.line!("  ${name}: ${program} MISMATCH on ${entry.path}: got ${got.len().to_str()} bytes, expected ${entry.content.len().to_str()}")?
		Err(Exit(1))
	}
}

# Run a command purely for its exit status.
expect_ok! : Str, List(OsStr), Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
expect_ok! = |program, arguments, name| {
	match Cmd.new(OsStr.from_str(program)).args(arguments).run!() {
		Ok(output) =>
			match output.status {
				Exited(0) => Ok({})
				status => {
					Stdout.line!("  ${name}: ${program} ${Str.inspect(status)}: ${output.stderr_utf8_lossy()}")?
					Err(Exit(1))
				}
			}
		Err(_) => {
			Stdout.line!("  ${name}: could not run ${program}")?
			Err(Exit(1))
		}
	}
}

is_ascii : Str -> Bool
is_ascii = |text| text.to_utf8().fold(Bool.True, |acc, byte| acc and byte < 0x80)

# The path with every run of non-ASCII bytes replaced by a single `*`.
bsdtar_pattern : Str -> Str
bsdtar_pattern = |path| {
	folded = path.to_utf8().fold({ out: [], in_run: Bool.False }, |acc, byte|
		if byte < 0x80 {
			{ out: acc.out.append(byte), in_run: Bool.False }
		} else if acc.in_run {
			acc
		} else {
			{ out: acc.out.append(0x2A), in_run: Bool.True }
		})
	Str.from_utf8_lossy(folded.out)
}

# Repetitive text, appended byte-wise into a bare list so the loop stays linear.
repeated_text : U64 -> List(U8)
repeated_text = |reps| {
	phrase = "Compression works best when text repeats itself. ".to_utf8()
	append_reps(List.with_capacity(reps * phrase.len() + 8), phrase, reps)
}

append_reps : List(U8), List(U8), U64 -> List(U8)
append_reps = |acc, phrase, remaining|
	if remaining == 0 {
		acc
	} else {
		append_reps(append_bytes(acc, phrase, 0), phrase, remaining - 1)
	}

append_bytes : List(U8), List(U8), U64 -> List(U8)
append_bytes = |acc, bytes, index|
	if index >= bytes.len() {
		acc
	} else {
		append_bytes(acc.append(bytes.get(index) ?? 0), bytes, index + 1)
	}
