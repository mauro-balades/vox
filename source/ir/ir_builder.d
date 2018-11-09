/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module ir.ir_builder;

import std.string : format;

import all;
import ir.ir_index;

//version = IrPrint;

// papers:
// 1. Simple and Efficient Construction of Static Single Assignment Form
struct IrBuilder
{
	CompilationContext* context;
	IrFunction* ir;

	// Stores current definition of variable per block during SSA-form IR construction.
	private IrIndex[BlockVarPair] blockVarDef;
	private IrIndex[IrIndex] blockToIrIncompletePhi;

	private IrVarId nextIrVarId;

	private IrVar returnVar;

	/// Must be called before compilation of each function. Allows reusing temp buffers.
	/// Sets up entry and exit basic blocks.
	void begin(IrFunction* ir, CompilationContext* context) {
		this.context = context;
		this.ir = ir;

		ir.storage = context.irBuffer.freePart;
		ir.storageLength = 0;

		blockVarDef.clear();

		setupEntryExitBlocks();

		if (ir.returnType != IrValueType.void_t)
		{
			IrIndex retIndex = addInstruction!IrReturnValueInstr(ir.exitBasicBlock);
			returnVar = IrVar(Identifier(0), newIrVarId());
			IrIndex retValue = readVariable(ir.exitBasicBlock, returnVar);
			ir.get!IrReturnValueInstr(retIndex).args[0] = retValue;
			addUser(retIndex, retValue);
		}
		else
		{
			addInstruction!IrReturnVoidInstr(ir.exitBasicBlock);
		}
		ir.getBlock(ir.exitBasicBlock).isFinished = true;
	}

	/// Must be called before IR to LIR pass
	void beginLir(IrFunction* lir, IrFunction* oldIr, CompilationContext* context) {
		this.context = context;
		this.ir = lir;

		ir.storage = context.irBuffer.freePart;
		ir.storageLength = 0;

		blockVarDef.clear();
	}

	void setupEntryExitBlocks()
	{
		assert(ir.numBasicBlocks == 0);
		// Canonical function CFG has entry block, and single exit block.
		ir.numBasicBlocks = 2;

		ir.entryBasicBlock = append!IrBasicBlockInstr;
		ir.exitBasicBlock = append!IrBasicBlockInstr;

		ir.getBlock(ir.entryBasicBlock).nextBlock = ir.exitBasicBlock;
		sealBlock(ir.entryBasicBlock);
		ir.getBlock(ir.exitBasicBlock).prevBlock = ir.entryBasicBlock;
		ir.lastBasicBlock = ir.entryBasicBlock;
	}

	/// Returns index to allocated item
	/// Allocates howMany items. By default allocates single item.
	/// If howMany > 1 - returns index of first item, access other items via IrIndex.indexOf
	/// T must have UDA of IrValueKind value
	IrIndex append(T)(uint howMany = 1)
	{
		IrIndex index = appendVoid!T(howMany);
		(&ir.get!T(index))[0..howMany] = T.init;
		return index;
	}

	/// Returns index to uninitialized memory for all requested items.
	/// Allocates howMany items. By default allocates single item.
	/// If howMany > 1 - resultIndex has index of first item, access other items via IrIndex.indexOf
	/// T must have UDA of IrValueKind value
	IrIndex appendVoid(T)(uint howMany = 1)
	{
		static assert(T.alignof == 4, "Can only store types aligned to 4 bytes");

		IrIndex resultIndex = IrIndex(ir.storageLength, getIrValueKind!T);

		enum allocSize = divCeil(T.sizeof, uint.sizeof);
		size_t numAllocatedSlots = allocSize * howMany;
		ir.storageLength += numAllocatedSlots;
		context.irBuffer.length += numAllocatedSlots;

		return resultIndex;
	}

	/// appendVoid + appendBlockInstr
	IrIndex appendVoidToBlock(T)(IrIndex blockIndex, uint howMany = 1)
	{
		IrIndex instr = appendVoid!T(howMany);
		appendBlockInstr(blockIndex, instr);
		return instr;
	}

	/// Adds control-flow edge pointing `fromBlock` -> `toBlock`.
	void addBlockTarget(IrIndex fromBasicBlockIndex, IrIndex toBasicBlockIndex) {
		ir.getBlock(fromBasicBlockIndex).successors.append(&this, toBasicBlockIndex);
		ir.getBlock(toBasicBlockIndex).predecessors.append(&this, fromBasicBlockIndex);
	}

	/// Sets lastBasicBlock to this block
	IrIndex addBasicBlock() {
		assert(ir.lastBasicBlock.isDefined);
		++ir.numBasicBlocks;
		IrIndex newBlock = append!IrBasicBlockInstr;
		ir.getBlock(newBlock).nextBlock = ir.getBlock(ir.lastBasicBlock).nextBlock;
		ir.getBlock(newBlock).prevBlock = ir.lastBasicBlock;
		ir.getBlock(ir.getBlock(ir.lastBasicBlock).nextBlock).prevBlock = newBlock;
		ir.getBlock(ir.lastBasicBlock).nextBlock = newBlock;
		ir.lastBasicBlock = newBlock;
		return ir.lastBasicBlock;
	}

	/// Does not remove its instructions/phis
	/*void removeBasicBlock(IrIndex basicBlockToRemove) {
		--numBasicBlocks;
		IrBasicBlockInstr* bb = &get!IrBasicBlockInstr(basicBlockToRemove);
		if (bb.prevBlock.isDefined)
			getBlock(bb.prevBlock).nextBlock = bb.nextBlock;
		if (bb.nextBlock.isDefined)
			getBlock(bb.nextBlock).prevBlock = bb.prevBlock;
	}*/

	// Algorithm 4: Handling incomplete CFGs
	/// Basic block is sealed if no further predecessors will be added to the block.
	/// Sealed block is not necessarily filled.
	/// Ignores already sealed blocks.
	void sealBlock(IrIndex basicBlockToSeal) {
		IrBasicBlockInstr* bb = &ir.getBlock(basicBlockToSeal);
		if (bb.isSealed) return;
		IrIndex index = blockToIrIncompletePhi.get(basicBlockToSeal, IrIndex());
		while (index.isDefined)
		{
			IrIncompletePhi ip = context.getTemp!IrIncompletePhi(index);
			addPhiOperands(basicBlockToSeal, ip.var, ip.phi);
			index = ip.nextListItem;
		}
		blockToIrIncompletePhi.remove(basicBlockToSeal);
		bb.isSealed = true;
	}

	/// Allocates new variable id for this function. It should be bound to a variable
	/// and used with writeVariable, readVariable functions
	IrVarId newIrVarId() {
		return IrVarId(nextIrVarId++);
	}

	// Algorithm 1: Implementation of local value numbering
	/// Redefines `variable` with `value`. Is used for assignment to variable
	void writeVariable(IrIndex blockIndex, IrVar variable, IrIndex value) {
		with(IrValueKind)
		{
			assert(
				value.kind == constant ||
				value.kind == virtualRegister ||
				value.kind == physicalRegister, format("%s", value));
		}
		blockVarDef[BlockVarPair(blockIndex, variable.id)] = value;
	}

	/// Returns the value that currently defines `variable` within `blockIndex`
	IrIndex readVariable(IrIndex blockIndex, IrVar variable) {
		if (auto irRef = BlockVarPair(blockIndex, variable.id) in blockVarDef)
			return *irRef;
		return readVariableRecursive(blockIndex, variable);
	}

	/// Puts `user` into a list of users of `used` value
	void addUser(IrIndex user, IrIndex used) {
		assert(user.isDefined, "user is undefined");
		assert(used.isDefined, "used is undefined");
		final switch (used.kind) with(IrValueKind) {
			case none: assert(false, "addUser none");
			case listItem: assert(false, "addUser listItem");
			case instruction: assert(false, "addUser instruction");
			case basicBlock: break; // allowed. As argument of jmp jcc
			case constant: break; // allowed, noop
			case phi: assert(false, "addUser phi"); // must be virt reg instead
			case memoryAddress: break; // allowed, noop
			case stackSlot: break; // allowed, noop
			case virtualRegister:
				ir.getVirtReg(used).users.append(&this, user);
				break;
			case physicalRegister: break; // allowed, noop
		}
	}

	IrIndex addInstruction(I)(IrIndex blockIndex)
	{
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);
		IrIndex instr = append!I;
		IrInstrHeader* instrHeader = &ir.get!IrInstrHeader(instr);
		instrHeader.op = getInstrInfo!I.opcode;
		instrHeader.prevInstr = block.lastInstr; // points to prev instruction or to null
		instrHeader.numArgs = getInstrInfo!I.numArgs;
		instrHeader.hasResult = getInstrInfo!I.hasResult;

		if (instrHeader.hasResult)
		{
			instrHeader.result = addVirtualRegister(instr);
		}

		if (!block.firstInstr.isDefined) {
			block.firstInstr = instr;
			block.lastInstr = instr;
		} else {
			ir.get!IrInstrHeader(block.lastInstr).nextInstr = instr;
			block.lastInstr = instr;
		}

		return instr;
	}

	/// Adds instruction to the end of basic block
	/// Doesn't set any instruction info except prevInstr index
	void appendBlockInstr(IrIndex blockIndex, IrIndex instr)
	{
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);

		IrInstrHeader* instrHeader = &ir.get!IrInstrHeader(instr);
		instrHeader.prevInstr = block.lastInstr; // points to prev instruction or to null

		if (!block.firstInstr.isDefined) {
			block.firstInstr = instr;
			block.lastInstr = instr;
		} else {
			ir.get!IrInstrHeader(block.lastInstr).nextInstr = instr;
			block.lastInstr = instr;
		}
	}

	/// Returns virtual register of result
	IrIndex emitBinaryInstr(IrIndex blockIndex, IrBinaryCondition cond, IrIndex arg0, IrIndex arg1)
	{
		auto instr = addInstruction!IrSetBinaryCondInstr(blockIndex);
		IrIndex vreg = addVirtualRegister(instr);
		with(ir.get!IrSetBinaryCondInstr(instr)) {
			header.cond = cond;
			args = [arg0, arg1];
			result = vreg;
		}
		return vreg;
	}

	/// Returns virtual register of result
	IrIndex emitBinaryInstr(IrIndex blockIndex, IrOpcode opcode, IrIndex arg0, IrIndex arg1)
	{
		alias InstT = IrBinaryExprInstr!(IrOpcode.invalid);
		auto instr = addInstruction!InstT(blockIndex);
		IrIndex vreg = addVirtualRegister(instr);
		with(ir.get!InstT(instr)) {
			args = [arg0, arg1];
			header.op = opcode; // replace IrOpcode.invalid with actual opcode
			result = vreg;
		}
		return vreg;
	}

	IrIndex addBinBranch(IrIndex blockIndex, IrBinaryCondition cond, IrIndex arg0, IrIndex arg1, ref IrLabel trueExit, ref IrLabel falseExit)
	{
		auto res = addBinBranch(blockIndex, cond, arg0, arg1);
		forceAllocLabelBlock(trueExit, 1);
		forceAllocLabelBlock(falseExit, 1);
		addBlockTarget(blockIndex, trueExit.blockIndex);
		addBlockTarget(blockIndex, falseExit.blockIndex);
		return res;
	}

	IrIndex addBinBranch(IrIndex blockIndex, IrBinaryCondition cond, IrIndex arg0, IrIndex arg1)
	{
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);
		assert(!block.isFinished);
		block.isFinished = true;
		auto branch = addInstruction!IrInstrBinaryBranch(blockIndex);
		with(ir.get!IrInstrBinaryBranch(branch)) {
			header.cond = cond;
			args = [arg0, arg1];
		}
		return branch;
	}

	IrIndex addUnaryBranch(IrIndex blockIndex, IrUnaryCondition cond, IrIndex arg0)
	{
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);
		assert(!block.isFinished);
		block.isFinished = true;
		auto branch = addInstruction!IrInstrBinaryBranch(blockIndex);
		with(ir.get!IrInstrUnaryBranch(branch)) {
			header.cond = cond;
			args = [arg0];
		}
		return branch;
	}

	void addReturn(IrIndex blockIndex, IrIndex returnValue)
	{
		assert(ir.returnType != IrValueType.void_t);
		writeVariable(blockIndex, returnVar, returnValue);
		addJump(blockIndex);
		addBlockTarget(blockIndex, ir.exitBasicBlock);
	}

	void addReturn(IrIndex blockIndex)
	{
		assert(ir.returnType == IrValueType.void_t);
		addJump(blockIndex);
		addBlockTarget(blockIndex, ir.exitBasicBlock);
	}

	IrIndex addJump(IrIndex blockIndex)
	{
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);
		assert(!block.isFinished);
		block.isFinished = true;
		return addInstruction!IrInstrJump(blockIndex);
	}

	void addJumpToLabel(IrIndex blockIndex, ref IrLabel label)
	{
		switch (label.numPredecessors)
		{
			case 0:
				// label.blockIndex points to block that started the scope
				// no block was created for label yet
				label.numPredecessors = 1;
				label.blockIndex = blockIndex;
				break;
			case 1:
				// label.blockIndex points to the only predecessor of label block
				// no block was created for label yet
				label.numPredecessors = 2;
				IrIndex firstPred = label.blockIndex;
				label.blockIndex = addBasicBlock;
				addBlockTarget(firstPred, label.blockIndex);
				// block may be finished if binary branch targets label
				//if (!ir.getBlock(firstPred).isFinished)
				addJump(firstPred);
				goto default;
			default:
				// label.blockIndex points to label's own block
				++label.numPredecessors;
				addBlockTarget(blockIndex, label.blockIndex);
				addJump(blockIndex);
				break;
		}
	}

	private void forceAllocLabelBlock(ref IrLabel label, int newPredecessors)
	{
		switch (label.numPredecessors)
		{
			case 0:
				// label.blockIndex points to block that started the scope
				// no block was created for label yet
				label.numPredecessors = newPredecessors;
				label.blockIndex = addBasicBlock;
				break;
			case 1:
				// label.blockIndex points to the only predecessor of label block
				// no block was created for label yet
				label.numPredecessors = 1 + newPredecessors;
				IrIndex firstPred = label.blockIndex;
				label.blockIndex = addBasicBlock;
				addBlockTarget(firstPred, label.blockIndex);
				addJump(firstPred);
				break;
			default:
				// label.blockIndex points to label's own block
				label.numPredecessors += newPredecessors;
				break;
		}
	}

	private void incBlockRefcount(IrIndex basicBlock) { assert(false); }
	private void decBlockRefcount(IrIndex basicBlock) { assert(false); }

	/// Creates virtual register to represent result of phi/instruction
	/// `definition` is phi/instruction that produces a value
	IrIndex addVirtualRegister(IrIndex definition)
	{
		uint seqIndex = ir.numVirtualRegisters;
		++ir.numVirtualRegisters;

		IrIndex virtRegIndex = append!IrVirtualRegister;
		IrVirtualRegister* virtReg = &ir.getVirtReg(virtRegIndex);
		virtReg.definition = definition;
		virtReg.seqIndex = seqIndex;
		if (ir.lastVirtualReg.isDefined) {
			ir.getVirtReg(ir.lastVirtualReg).nextVirtReg = virtRegIndex;
		} else {
			ir.firstVirtualReg = virtRegIndex;
		}
		virtReg.prevVirtReg = ir.lastVirtualReg;
		ir.lastVirtualReg = virtRegIndex;
		return virtRegIndex;
	}

	// ignores null opdId
	private void removeVirtualRegister(IrIndex virtRegIndex)
	{
		// TODO: freelist?
		IrVirtualRegister* virtReg = &ir.getVirtReg(virtRegIndex);
		if (virtRegIndex == ir.firstVirtualReg)
			ir.firstVirtualReg = virtReg.nextVirtReg;
		if (virtRegIndex == ir.lastVirtualReg)
			ir.lastVirtualReg = virtReg.prevVirtReg;
		if (virtReg.prevVirtReg.isDefined)
			ir.getVirtReg(virtReg.prevVirtReg).nextVirtReg = virtReg.nextVirtReg;
		if (virtReg.nextVirtReg.isDefined)
			ir.getVirtReg(virtReg.nextVirtReg).prevVirtReg = virtReg.prevVirtReg;
		--ir.numVirtualRegisters;
		if (ir.lastVirtualReg.isDefined)
			ir.getVirtReg(ir.lastVirtualReg).seqIndex = virtReg.seqIndex;
	}

	// Adds phi function to specified block
	IrIndex addPhi(IrIndex blockIndex)
	{
		IrIndex phiIndex = append!IrPhiInstr;
		IrIndex vreg = addVirtualRegister(phiIndex);
		ir.get!IrPhiInstr(phiIndex) = IrPhiInstr(blockIndex, vreg);
		IrBasicBlockInstr* block = &ir.getBlock(blockIndex);
		if (block.firstPhi.isDefined) {
			ir.get!IrPhiInstr(block.firstPhi).prevPhi = phiIndex;
			ir.get!IrPhiInstr(phiIndex).nextPhi = block.firstPhi;
		}
		block.firstPhi = phiIndex;
		return phiIndex;
	}

	private void removePhi(IrIndex phiIndex)
	{
		version(IrPrint) writefln("[IR] remove phi %s", phiIndex);
		IrPhiInstr* phi = &ir.get!IrPhiInstr(phiIndex);
		IrBasicBlockInstr* block = &ir.getBlock(phi.blockIndex);
		version(IrPrint) {
			foreach(IrIndex phiIndex, ref IrPhiInstr phi; block.phis(ir)) {
				writefln("[IR]   %s = %s", phi.result, phiIndex);
			}
		}
		// TODO: free list of phis
		if (block.firstPhi == phiIndex) block.firstPhi = phi.nextPhi;
		if (phi.nextPhi.isDefined) ir.get!IrPhiInstr(phi.nextPhi).prevPhi = phi.prevPhi;
		if (phi.prevPhi.isDefined) ir.get!IrPhiInstr(phi.prevPhi).nextPhi = phi.nextPhi;
		version(IrPrint) writefln("[IR] after remove phi %s", phiIndex);
		version(IrPrint) {
			IrBasicBlockInstr* block1 = &ir.getBlock(phi.blockIndex);
			foreach(IrIndex phiIndex, ref IrPhiInstr phi; block1.phis(ir)) {
				writefln("[IR]   %s = %s", phi.result, phiIndex);
			}
		}
	}

	// Algorithm 2: Implementation of global value numbering
	/// Returns the last value of the variable in basic block
	private IrIndex readVariableRecursive(IrIndex blockIndex, IrVar variable) {
		IrIndex value;
		if (!ir.getBlock(blockIndex).isSealed) {
			// Incomplete CFG
			IrIndex phiIndex = addPhi(blockIndex);
			value = ir.get!IrPhiInstr(phiIndex).result;
			blockToIrIncompletePhi.update(blockIndex,
				{
					IrIndex incompletePhi = context.appendTemp!IrIncompletePhi;
					context.getTemp!IrIncompletePhi(incompletePhi) = IrIncompletePhi(variable, phiIndex);
					return incompletePhi;
				},
				(ref IrIndex oldPhi)
				{
					IrIndex incompletePhi = context.appendTemp!IrIncompletePhi;
					context.getTemp!IrIncompletePhi(incompletePhi) = IrIncompletePhi(variable, phiIndex, oldPhi);
					return incompletePhi;
				});
		}
		else
		{
			SmallVector preds = ir.getBlock(blockIndex).predecessors;
			if (preds.length == 1) {
				// Optimize the common case of one predecessor: No phi needed
				value = readVariable(preds[0, *ir], variable);
			}
			else
			{
				// Break potential cycles with operandless phi
				IrIndex phiIndex = addPhi(blockIndex);
				value = ir.get!IrPhiInstr(phiIndex).result;
				writeVariable(blockIndex, variable, value);
				value = addPhiOperands(blockIndex, variable, phiIndex);
			}
		}
		with(IrValueKind)
		{
			assert(
				value.kind == constant ||
				value.kind == virtualRegister ||
				value.kind == physicalRegister, format("%s", value));
		}
		writeVariable(blockIndex, variable, value);
		return value;
	}

	// Adds all values of variable as arguments of phi. Values are gathered from block's predecessors.
	// Returns either φ result virtual register or one of its arguments if φ is trivial
	private IrIndex addPhiOperands(IrIndex blockIndex, IrVar variable, IrIndex phi) {
		// Determine operands from predecessors
		foreach (i, predIndex; ir.getBlock(blockIndex).predecessors.range(*ir))
		{
			IrIndex value = readVariable(predIndex, variable);
			version(IrPrint) writefln("[IR] phi operand %s", value);
			// Phi should not be cached before loop, since readVariable can add phi to phis, reallocating the array
			addPhiArg(phi, predIndex, value);
			addUser(phi, value);
		}
		return tryRemoveTrivialPhi(phi);
	}

	void addPhiArg(IrIndex phiIndex, IrIndex blockIndex, IrIndex value)
	{
		IrIndex phiArg = append!IrPhiArg;
		auto phi = &ir.get!IrPhiInstr(phiIndex);
		ir.get!IrPhiArg(phiArg) = IrPhiArg(value, blockIndex, phi.firstArgListItem);
		phi.firstArgListItem = phiArg;
	}

	// Algorithm 3: Detect and recursively remove a trivial φ function
	// Returns either φ result virtual register or one of its arguments if φ is trivial
	private IrIndex tryRemoveTrivialPhi(IrIndex phiIndex) {
		IrPhiArg same;
		foreach (size_t i, ref IrPhiArg phiArg; ir.get!IrPhiInstr(phiIndex).args(*ir))
		{
			version(IrPrint) writefln("[IR] arg %s", phiArg.value);
			if (phiArg.value == same.value || phiArg.value == phiIndex) {
				version(IrPrint) writefln("[IR]   same");
				continue; // Unique value or self−reference
			}
			if (same != IrPhiArg()) {
				version(IrPrint) writefln("[IR]   non-trivial");
				return ir.get!IrPhiInstr(phiIndex).result; // The phi merges at least two values: not trivial
			}
			version(IrPrint) writefln("[IR]   same = %s", phiArg.value);
			same = phiArg;
		}
		version(IrPrint) writefln("[IR]   trivial");
		assert(same.value.isDefined, "Phi function got no arguments");

		// Remember all users except the phi itself
		IrIndex phiResultIndex = ir.get!IrPhiInstr(phiIndex).result;
		assert(phiResultIndex.kind == IrValueKind.virtualRegister, format("%s", phiResultIndex));

		SmallVector users = ir.getVirtReg(phiResultIndex).users;

		// Reroute all uses of phi to same and remove phi
		replaceBy(users, phiResultIndex, same);
		removePhi(phiIndex);

		// Try to recursively remove all phi users, which might have become trivial
		foreach (i, index; users.range(*ir))
			if (index.kind == IrValueKind.phi && index != phiIndex)
				tryRemoveTrivialPhi(index);

		removeVirtualRegister(phiResultIndex);
		return same.value;
	}

	IrIndex definitionOf(IrIndex someIndex)
	{
		final switch (someIndex.kind) with(IrValueKind) {
			case none: assert(false);
			case listItem: assert(false);
			case instruction: return someIndex;
			case basicBlock: assert(false);
			case constant: assert(false);
			case phi: return someIndex;
			case memoryAddress: assert(false); // TODO
			case stackSlot: assert(false); // TODO
			case virtualRegister: return ir.getVirtReg(someIndex).definition;
			case physicalRegister: assert(false);
		}
	}

	// ditto
	/// Rewrites all users of phi to point to `byWhat` instead of its result `what`.
	/// `what` is the result of phi (vreg), `phiUsers` is users of `what`
	private void replaceBy(SmallVector phiUsers, IrIndex what, IrPhiArg byWhat) {
		foreach (size_t i, IrIndex userIndex; phiUsers.range(*ir))
		{
			final switch (userIndex.kind) with(IrValueKind) {
				case none: assert(false);
				case listItem: assert(false);
				case instruction:
					foreach (ref IrIndex arg; ir.get!IrInstrHeader(userIndex).args)
						if (arg == what)
						{
							arg = byWhat.value;
							replaceUserWith(byWhat.value, definitionOf(what), userIndex);
						}
					break;
				case basicBlock: assert(false);
				case constant: assert(false);
				case phi:
					foreach (size_t i, ref IrPhiArg phiArg; ir.get!IrPhiInstr(userIndex).args(*ir))
						if (phiArg.value == what)
						{
							phiArg = byWhat;
							replaceUserWith(byWhat.value, definitionOf(what), userIndex);
						}
					break;
				case memoryAddress: assert(false); // TODO
				case stackSlot: assert(false); // TODO
				case virtualRegister: assert(false);
				case physicalRegister: assert(false);
			}
		}
	}

	private void replaceUserWith(IrIndex used, IrIndex what, IrIndex byWhat) {
		final switch (used.kind) with(IrValueKind) {
			case none, listItem, basicBlock, physicalRegister: assert(false);
			case instruction: return ir.getVirtReg(ir.get!IrInstrHeader(used).result).users.replaceAll(*ir, what, byWhat);
			case constant: return; // constants dont track users
			case phi: return ir.getVirtReg(ir.get!IrPhiInstr(used).result).users.replaceAll(*ir, what, byWhat);
			case memoryAddress: assert(false); // TODO, has single user
			case stackSlot: assert(false); // TODO
			case virtualRegister: return ir.getVirtReg(used).users.replaceAll(*ir, what, byWhat);
		}
	}
}
