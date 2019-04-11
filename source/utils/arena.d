/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module utils.arena;

///
struct Arena(T)
{
	import utils : alignValue, max, format, to, PAGE_SIZE;
	import std.range : isInputRange;
	import core.sys.windows.windows : VirtualAlloc, MEM_COMMIT, PAGE_READWRITE;

	T* bufPtr;
	/// How many items can be stored without commiting more memory (committed items)
	size_t capacity;
	/// Number of items in the buffer. length <= capacity
	size_t length;
	/// Total reserved bytes
	size_t reservedBytes;

	size_t committedBytes() { return alignValue(capacity * T.sizeof, PAGE_SIZE); }

	uint uintLength() { return length.to!uint; }
	size_t byteLength() { return length * T.sizeof; }
	ref T opIndex(size_t at) { return bufPtr[at]; }
	ref T back() { return bufPtr[length-1]; }
	inout(T[]) data() inout { return bufPtr[0..length]; }
	bool empty() { return length == 0; }
	T* nextPtr() { return bufPtr + length; }
	bool contains(void* ptr) { return bufPtr <= cast(T*)ptr && cast(T*)ptr <= bufPtr + length; }

	void setBuffer(ubyte[] reservedBuffer) {
		setBuffer(reservedBuffer, reservedBuffer.length);
	}
	void setBuffer(ubyte[] reservedBuffer, size_t committedBytes) {
		bufPtr = cast(T*)reservedBuffer.ptr;
		assert(bufPtr, "reservedBuffer is null");
		reservedBytes = reservedBuffer.length;
		// we can lose [0; T.sizeof-1] bytes here, need to round up to multiple of allocation size when committing
		capacity = committedBytes / T.sizeof;
		length = 0;
	}
	void clear() { length = 0; }

	void put(T[] items ...) {
		if (capacity - length < items.length) makeSpace(items.length);
		//writefln("assign %X.%s @ %s..%s+%s = %s", bufPtr, T.sizeof, length, length, items.length, items);
		bufPtr[length..length+items.length] = items;
		length += items.length;
	}

	void put(R)(R itemRange) if (isInputRange!R) {
		foreach(item; itemRange)
			put(item);
	}

	void stealthPut(T item) {
		if (capacity == length) makeSpace(1);
		bufPtr[length] = item;
	}

	/// Increases length and returns void-initialized slice to be filled by user
	T[] voidPut(size_t howMany) {
		if (capacity - length < howMany) makeSpace(howMany);
		length += howMany;
		return bufPtr[length-howMany..length];
	}

	static if (is(T == ubyte))
	{
		void put(V)(V value) {
			ubyte[V.sizeof] buf = *cast(ubyte[V.sizeof]*)&value;
			put(buf);
		}

		void pad(size_t bytes) {
			voidPut(bytes)[] = 0;
		}
	}

	void makeSpace(size_t items) {
		assert(items > (capacity - length));
		size_t _committedBytes = committedBytes;
		size_t itemsToCommit = items - (capacity - length);
		size_t bytesToCommit = alignValue((items - (capacity - length)) * T.sizeof, PAGE_SIZE);
		bytesToCommit = max(bytesToCommit, PAGE_SIZE);

		version(Windows)
		{
			if (_committedBytes + bytesToCommit > reservedBytes)
			{
				assert(false, format("out of memory: reserved %s, committed bytes %s, requested %s",
					reservedBytes, _committedBytes, bytesToCommit));
			}

			import core.sys.windows.windows;
			void* result = VirtualAlloc(cast(ubyte*)bufPtr + _committedBytes, bytesToCommit, MEM_COMMIT, PAGE_READWRITE);
			if (result is null) assert(false, "Cannot commit more bytes");
		}
		else version(Posix)
		{
			static assert(false, "Not implemented for Posix");
		}

		capacity = (_committedBytes + bytesToCommit) / T.sizeof;
	}
}
