#
# = Introduction
#
# This file intends to provide file system-like api support, a la <tt>zip/zipfilesystem</tt>.
#
# Ideally, this will be the recommended interface, allowing Ole::Storage, Dir, and
# Zip::ZipFile to be used exchangably. It should be possible to write recursive copy using
# the plain api, such that you can copy dirs/files agnostically between any of ole docs, dirs,
# and zip files.
#
# = Usage
#
# Currently you can do something like the following:
#
#   Ole::Storage.open 'test.doc' do |ole|
#     ole.dir.entries '/'         # => [".", "..", "\001Ole", "1Table", "\001CompObj", ...]
#     ole.file.read "\001CompObj" # => "\001\000\376\377\003\n\000\000\377\377..."
#   end
#
# = Notes
#
# <tt>Ole::Storage</tt> files can have multiple files with the same name,
# or with / in the name, and other things that are probably invalid anyway.
# This API is unable to access those files, but of course the core, low-
# level API can.
#
# need to implement some more IO functions on RangesIO, like #puts, #print
# etc, like AbstractOutputStream from zipfile.
#

require 'ole/storage'

module Ole # :nodoc:
	class Storage
		def file
			@file ||= FileClass.new self
		end

		def dir
			@dir ||= DirClass.new self
		end

		# tries to get a dirent for path. return nil if it doesn't exist
		# (change it)
		def dirent_from_path path
			dirent = @root
			path = file.expand_path path
			path = path.sub(/^\/*/, '').sub(/\/*$/, '').split(/\/+/)
			until path.empty?
				return nil if dirent.file?
				return nil unless dirent = dirent[path.shift]
			end
			dirent
		end

		class FileClass
			def initialize ole
				@ole = ole
			end

			def expand_path path
				# its only absolute if it starts with a '/'
				path = "#{@ole.dir.pwd}/#{path}" unless path =~ /^\//
				# at this point its already absolute. we use File.expand_path
				# just for the .. and . handling
				File.expand_path path
			end

			# +orig_path+ is just so that we can use the requested path
			# in the error messages even if it has been already modified
			def dirent_from_path path, orig_path=nil
				orig_path ||= path
				dirent = @ole.dirent_from_path path
				raise Errno::ENOENT,  orig_path unless dirent
				raise Errno::EISDIR, orig_path if dirent.dir?
				dirent
			end
			private :dirent_from_path

			def exists? path
				!!@ole.dirent_from_path(path)
			end
			alias exist? :exists?

			def file? path
				dirent = @ole.dirent_from_path path
				dirent and dirent.file?
			end

			def directory? path
				dirent = @ole.dirent_from_path path
				dirent and dirent.dir?
			end

			def open path, mode='r', &block
				# FIXME - mode strings are more complex than this.
				if mode == 'w'
					begin
						dirent = dirent_from_path path
					rescue Errno::ENOENT
						# maybe instead of repeating this everywhere, i should have
						# a get_parent_dirent function.
						parent_path, basename = File.split expand_path(path)
						parent = @ole.dir.send :dirent_from_path, parent_path, path
						dirent = parent.new_child :file
						dirent.name = basename
					end
				else
					dirent = dirent_from_path path
				end
				# i think mode is supposed to be passed here too
				dirent.open(&block)
			end
			alias new :open

			def size path
				dirent_from_path(path).size
			end

			def read path
				open path, &:read
			end

			# crappy copy from Dir.
			def unlink path
				dirent = @ole.dirent_from_path path
				# EPERM
				raise "operation not permitted #{path.inspect}" unless dirent.file?
				# i think we should free all of our blocks. i think the best way to do that would be
				# like:
				# open(path) { |f| f.truncate 0 }. which should free all our blocks from the
				# allocation table. then if we remove ourself from our parent, we won't be part of
				# the bat at save time.
				# i think if you run repack, all free blocks should get zeroed.
				open(path) { |f| f.truncate 0 }
				parent = @ole.dirent_from_path(('/' + path).sub(/\/[^\/]+$/, ''))
				parent.children.delete dirent
				1 # hmmm. as per ::File ?
			end
		end

		#
		# an *instance* of this class is supposed to provide similar methods
		# to the class methods of Dir itself.
		#
		# pretty complete. like zip/zipfilesystem's implementation, i provide
		# everything except chroot and glob. glob could be done with a glob
		# to regex regex, and then simply match in the entries array... although
		# recursive glob complicates that somewhat.
		#
		# Dir.chroot, Dir.glob, Dir.[], and Dir.tmpdir is the complete list.
		class DirClass
			def initialize ole
				@ole = ole
				@pwd = ''
			end

			# +orig_path+ is just so that we can use the requested path
			# in the error messages even if it has been already modified
			def dirent_from_path path, orig_path=nil
				orig_path ||= path
				dirent = @ole.dirent_from_path path
				raise Errno::ENOENT,  orig_path unless dirent
				raise Errno::ENOTDIR, orig_path unless dirent.dir?
				dirent
			end
			private :dirent_from_path

			def open path
				dir = Dir.new path, entries(path)
				if block_given?
					yield dir
				else
					dir
				end
			end
			alias new :open

			# pwd is always stored without the trailing slash. we handle
			# the root case here
			def pwd
				if @pwd.empty?
					'/'
				else
					@pwd
				end
			end
			alias getwd :pwd

			def chdir orig_path
				# make path absolute, squeeze slashes, and remove trailing slash
				path = @ole.file.expand_path(orig_path).gsub(/\/+/, '/').sub(/\/$/, '')
				# this is just for the side effects of the exceptions if invalid
				dirent_from_path path, orig_path
				if block_given?
					old_pwd = @pwd
					begin
						@pwd = path
						yield
					ensure
						@pwd = old_pwd
					end
				else
					@pwd = path
					0
				end
			end	

			def entries path
				dirent = dirent_from_path path
				# Not sure about adding on the dots...
				entries = %w[. ..] + dirent.children.map(&:name)
			end

			def foreach path, &block
				entries(path).each(&block)
			end

			# there are some other important ones, like:
			# chroot (!), glob etc etc. for now, i think
			def mkdir path
				# as for rmdir below:
				parent_path, basename = File.split @ole.file.expand_path(path)
				# note that we will complain about the full path despite accessing
				# the parent path. this is consistent with ::Dir
				parent = dirent_from_path parent_path, path
				# now, we first should ensure that it doesn't already exist
				# either as a file or a directory.
				raise Errno::EEXIST, path if parent[basename]
				parent.new_child(:dir) { |child| child.name = basename }
				0
			end

			def rmdir path
				dirent = dirent_from_path path
				raise Errno::ENOTEMPTY, orig_path unless dirent.children.empty?

				# now delete it, how to do that? the canonical representation that is
				# maintained is the root tree, and the children array. we must remove it
				# from the children array.
				# we need the parent then. this sucks but anyway:
				# we need to split the path. but before we can do that, we need
				# to expand it first. eg. say we need the parent to unlink
				# a/b/../c. the parent should be a, not a/b/.., or a/b.
				parent_path, basename = File.split @ole.file.expand_path(path)
				# this shouldn't be able to fail if the above didn't
				parent = dirent_from_path parent_path
				# note that the way this currently works, on save and repack time this will get
				# reflected. to work properly, ie to make a difference now it would have to re-write
				# the dirent. i think that Ole::Storage#close will handle that. and maybe include a
				# #repack.
				parent.children.delete dirent
				0 # hmmm. as per ::Dir ?
			end
			alias delete :rmdir
			alias unlink :rmdir

			# note that there is nothing remotely ole specific about
			# this class. it simply provides the dir like sequential access
			# methods on top of an array.
			# hmm, doesn't throw the IOError's on use of a closed directory...
			class Dir
				include Enumerable

				attr_reader :path, :entries, :pos
				def initialize path, entries
					@path, @entries, @pos = path, entries, 0
				end

				def each(&block)
					entries.each(&block)
				end

				def close
				end

				def read
					entries[pos]
				ensure
					@pos += 1 if pos < entries.length
				end

				def pos= pos
					@pos = [[0, pos].max, entries.length].min
				end

				def rewind
					@pos = 0
				end

				alias tell :pos
				alias seek :pos=
			end
		end
	end
end
