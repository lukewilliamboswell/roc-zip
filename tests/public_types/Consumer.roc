## Exercise the types through a package import, not inside Zip's own module.
import zip.Zip

Consumer := [].{}

copy_entry : Zip.Writer, Zip.Compressed -> Try(List(U8), Zip.CreateError)
copy_entry = |writer, stored| {
	added = Zip.add(writer, Copied(stored))?
	Ok(added.chunk.concat(Zip.finish(added.writer)))
}

read_stored : List(U8), Zip.Entry -> Try(Zip.Compressed, Zip.ExtractError)
read_stored = |bytes, entry| Zip.compressed(bytes, entry)

expect {
	file : Zip.ZipEntry
	file = { path: "hello.txt", content: "hello".to_utf8() }
	level : Zip.Compression
	level = None
	archive = Zip.create([file], level) ?? []
	index = Zip.entries(archive) ?? []
	match index {
		[entry] => match read_stored(archive, entry) {
			Ok(stored) => copy_entry(Zip.writer({ compression: level }), stored) == Ok(archive)
			Err(_) => Bool.False
		}
		_ => Bool.False
	}
}
