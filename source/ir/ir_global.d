/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
/// IR global. Stores info about global variables, string/array/struct literals.
module ir.ir_global;

import all;

enum IrGlobalFlags : uint {
	isMutable = 1 << 0,
	isAllZero = 1 << 1,
	needsZeroTermination = 1 << 2,
	/// Global data is copied into static data buffer (or zeroes are reserved for isAllZero)
	/// If (and only if) set, then staticBufferOffset must be valid
	isInBuffer = 1 << 3,
}

///
@(IrValueKind.global)
struct IrGlobal
{
	/// Is null, or
	/// Points to source code for string literals, or
	/// Points to static data buffer
	ubyte[] initializer;
	/// set of IrGlobalFlags
	uint flags;
	/// Is zero until static data layout is finalized
	uint staticBufferOffset;
	/// doesn't include zero terminator when needsZeroTermination is set
	/// Must be equal to initializer.length if it is set
	uint length;
	///
	uint alignment = 1;
	///
	uint numUsers;

	bool isMutable() { return (flags & IrGlobalFlags.isMutable) != 0; }
	bool needsZeroTermination() { return (flags & IrGlobalFlags.needsZeroTermination) != 0; }
	bool isInBuffer() { return (flags & IrGlobalFlags.isInBuffer) != 0; }

	void addUser(IrIndex user) { ++numUsers; }
	void removeUser(IrIndex user) { --numUsers; }
	void setInitializer(ubyte[] data) {
		initializer = data;
		assert(data.length <= 1024*1024*1024*2, "initializer is bigger than 2GB");
		length = cast(uint)data.length;
	}
}
