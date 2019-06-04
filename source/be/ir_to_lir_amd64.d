/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module be.ir_to_lir_amd64;

import std.stdio;
import all;


void pass_ir_to_lir_amd64(ref CompilationContext context, ref ModuleDeclNode mod, ref FunctionDeclNode func)
{
	auto pass = IrToLir(&context);
	pass.run(mod, func);
}

struct IrToLir
{
	CompilationContext* context;
	IrBuilder builder;

	void run(ref ModuleDeclNode mod, ref FunctionDeclNode func)
	{
		if (func.isExternal) return;

		func.backendData.lirData = context.appendAst!IrFunction;
		func.backendData.lirData.backendData = &func.backendData;

		mod.lirModule.addFunction(*context, func.backendData.lirData);
		processFunc(*func.backendData.irData, *func.backendData.lirData);
		if (context.validateIr) validateIrFunction(*context, *func.backendData.lirData);
		if (context.printLir && context.printDumpOf(&func)) dumpFunction(*func.backendData.lirData, *context);
	}

	void processFunc(ref IrFunction ir, ref IrFunction lir)
	{
		//writefln("IR to LIR %s", context.idString(ir.name));
		lir.instructionSet = IrInstructionSet.lir_amd64;

		context.tempBuffer.clear;

		builder.beginLir(&lir, &ir, context);

		// Mirror of original IR, we will put the new IrIndex of copied entities there
		// and later use this info to rewire all connections between basic blocks
		IrMirror!IrIndex mirror;
		mirror.create(context, &ir);

		// save map from old index to new index
		void recordIndex(IrIndex oldIndex, IrIndex newIndex)
		{
			assert(oldIndex.isDefined);
			assert(newIndex.isDefined);
			mirror[oldIndex] = newIndex;
		}

		IrIndex newIndexFromOldIndex(IrIndex oldIndex)
		{
			return mirror[oldIndex];
		}

		void fixIndex(ref IrIndex index)
		{
			assert(index.isDefined);
			if (index.isBasicBlock || index.isVirtReg || index.isPhi || index.isInstruction) {
				//writefln("%s -> %s", index, mirror[index]);
				index = mirror[index];
			}
		}

		IrIndex prevBlock;
		// dup basic blocks
		foreach (IrIndex blockIndex, ref IrBasicBlock irBlock; ir.blocks)
		{
			++lir.numBasicBlocks;
			IrIndex lirBlock = builder.append!IrBasicBlock;
			recordIndex(blockIndex, lirBlock);

			lir.getBlock(lirBlock).name = irBlock.name;
			lir.getBlock(lirBlock).isLoopHeader = irBlock.isLoopHeader;

			foreach(IrIndex pred; irBlock.predecessors.range(ir)) {
				lir.getBlock(lirBlock).predecessors.append(&builder, pred);
			}
			foreach(IrIndex succ; irBlock.successors.range(ir)) {
				lir.getBlock(lirBlock).successors.append(&builder, succ);
			}

			// temporarily store link to old block
			lir.getBlock(lirBlock).firstInstr = blockIndex;

			if (blockIndex == ir.entryBasicBlock) {
				lir.entryBasicBlock = lirBlock;
			} else if (blockIndex == ir.exitBasicBlock) {
				lir.exitBasicBlock = lirBlock;
				lir.getBlock(lirBlock).prevBlock = prevBlock;
				lir.getBlock(prevBlock).nextBlock = lirBlock;
			} else {
				lir.getBlock(lirBlock).prevBlock = prevBlock;
				lir.getBlock(prevBlock).nextBlock = lirBlock;
			}

			// Add phis with old args
			foreach(IrIndex phiIndex, ref IrPhi phi; irBlock.phis(ir))
			{
				IrIndex newPhi = builder.addPhi(lirBlock);
				recordIndex(phiIndex, newPhi);
				IrIndex newResult = lir.getPhi(newPhi).result;
				IrVirtualRegister* newReg = &lir.getVirtReg(newResult);
				IrVirtualRegister* oldReg = &ir.getVirtReg(phi.result);
				newReg.type = oldReg.type;

				recordIndex(phi.result, lir.getPhi(newPhi).result);
				foreach(size_t arg_i, ref IrPhiArg phiArg; phi.args(ir))
				{
					builder.addPhiArg(newPhi, phiArg.basicBlock, phiArg.value);
				}
			}

			prevBlock = lirBlock;
		}

		// buffer for call/instruction arguments
		enum MAX_ARGS = 255;
		IrIndex[MAX_ARGS] argBuffer;

		// fix successors predecessors links
		foreach (IrIndex lirBlockIndex, ref IrBasicBlock lirBlock; lir.blocks)
		{
			lirBlock.isSealed = true;
			lirBlock.isFinished = true;

			foreach(ref pred; lirBlock.predecessors.range(lir)) fixIndex(pred);
			foreach(ref succ; lirBlock.successors.range(lir)) fixIndex(succ);

			// get the temp and null it
			IrIndex irBlockIndex = lirBlock.firstInstr;
			lirBlock.firstInstr = IrIndex();

			// Add instructions with old args
			foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; ir.getBlock(irBlockIndex).instructions(ir))
			{
				auto emitLirInstr(I)()
				{
					static if (getInstrInfo!I.hasResult)
					{
						IrIndex type = ir.getVirtReg(instrHeader.result).type;
						ExtraInstrArgs extra = { addUsers : false, argSize : instrHeader.argSize, type : type };
						InstrWithResult res = builder.emitInstr!I(lirBlockIndex, extra, instrHeader.args);
						recordIndex(instrIndex, res.instruction);
						recordIndex(instrHeader.result, res.result);
					}
					else
					{
						ExtraInstrArgs extra = { addUsers : false, argSize : instrHeader.argSize };
						IrIndex res = builder.emitInstr!I(lirBlockIndex, extra, instrHeader.args);
						recordIndex(instrIndex, res);
					}
				}

				void movIntoReg(IrIndex from, IrIndex to) {
					ExtraInstrArgs extra = { addUsers : false, result : to };
					builder.emitInstr!LirAmd64Instr_mov(lirBlockIndex, extra, from);
				}

				switch(instrHeader.op)
				{
					case IrOpcode.parameter:
						uint paramIndex = ir.get!IrInstr_parameter(instrIndex).index;
						context.assertf(paramIndex < lir.backendData.callingConvention.paramsInRegs.length,
							"Only parameters passed through registers are implemented");

						IrIndex paramReg = lir.backendData.callingConvention.paramsInRegs[paramIndex];
						IrIndex type = ir.getVirtReg(instrHeader.result).type;
						paramReg.physRegSize = typeToRegSize(type, context);
						ExtraInstrArgs extra = {type : type};
						InstrWithResult instr = builder.emitInstr!LirAmd64Instr_mov(lirBlockIndex, extra, paramReg);
						recordIndex(instrIndex, instr.instruction);
						recordIndex(instrHeader.result, instr.result);
						break;

					// TODO. Win64 call conv is hardcoded here
					case IrOpcode.call:

						enum STACK_ITEM_SIZE = 8;
						size_t numArgs = instrHeader.args.length;
						size_t numParamsInRegs = lir.backendData.callingConvention.paramsInRegs.length;
						// how many bytes are allocated on the stack before func call
						size_t stackReserve = max(numArgs, numParamsInRegs) * STACK_ITEM_SIZE;
						IrIndex stackPtrReg = lir.backendData.callingConvention.stackPointer;

						if (numArgs > numParamsInRegs)
						{
							if (numArgs % 2 == 1)
							{	// align stack to 16 bytes
								stackReserve += STACK_ITEM_SIZE;
								IrIndex paddingSize = context.constants.add(STACK_ITEM_SIZE, IsSigned.no);
								ExtraInstrArgs extra = {addUsers : false, result : stackPtrReg};
								builder.emitInstr!LirAmd64Instr_sub(
									lirBlockIndex, extra, stackPtrReg, paddingSize);
							}

							// push args to stack
							foreach_reverse (IrIndex arg; instrHeader.args[numParamsInRegs..$])
							{
								ExtraInstrArgs extra = {addUsers : false};
								builder.emitInstr!LirAmd64Instr_push(lirBlockIndex, extra, arg);
							}
						}

						// move args to registers
						size_t numPhysRegs = min(numParamsInRegs, numArgs);
						foreach_reverse (i, IrIndex arg; instrHeader.args[0..numPhysRegs])
						{
							IrIndex type = ir.getValueType(*context, arg);
							IrIndex argRegister = lir.backendData.callingConvention.paramsInRegs[i];
							argRegister.physRegSize = typeToRegSize(type, context);
							argBuffer[i] = argRegister;
							ExtraInstrArgs extra = {addUsers : false, result : argRegister};
							builder.emitInstr!LirAmd64Instr_mov(lirBlockIndex, extra, arg);
						}
						{	// Allocate shadow space for 4 physical registers
							IrIndex const_32 = context.constants.add(32, IsSigned.no);
							ExtraInstrArgs extra = {addUsers : false, result : stackPtrReg};
							builder.emitInstr!LirAmd64Instr_sub(
								lirBlockIndex, extra, stackPtrReg, const_32);
						}

						{	// call
							ExtraInstrArgs callExtra = {
								addUsers : false,
								hasResult : instrHeader.hasResult,
								result : lir.backendData.callingConvention.returnReg // will be used if function has result
							};

							FunctionIndex calleeIndex = instrHeader.preheader!IrInstrPreheader_call.calleeIndex;
							builder.emitInstrPreheader(IrInstrPreheader_call(calleeIndex));
							InstrWithResult callInstr = builder.emitInstr!LirAmd64Instr_call(
								lirBlockIndex, callExtra, argBuffer[0..numPhysRegs]);
							recordIndex(instrIndex, callInstr.instruction);

							{	// Deallocate stack after call
								IrIndex conReservedBytes = context.constants.add(stackReserve, IsSigned.no);
								ExtraInstrArgs extra = {addUsers : false, result : stackPtrReg};
								builder.emitInstr!LirAmd64Instr_add(
									lirBlockIndex, extra, stackPtrReg, conReservedBytes);
							}

							if (callExtra.hasResult) {
								// mov result to virt reg
								ExtraInstrArgs extra = { type : ir.getVirtReg(instrHeader.result).type };
								InstrWithResult movInstr = builder.emitInstr!LirAmd64Instr_mov(
									lirBlockIndex, extra, lir.backendData.callingConvention.returnReg);
								recordIndex(instrHeader.result, movInstr.result);
							}
						}

						break;

					case IrOpcode.add: emitLirInstr!LirAmd64Instr_add; break;
					case IrOpcode.sub: emitLirInstr!LirAmd64Instr_sub; break;
					case IrOpcode.mul: emitLirInstr!LirAmd64Instr_imul; break;
					case IrOpcode.shl:
						IrIndex rightArg = amd64_reg.cx;
						rightArg.physRegSize = ArgType.BYTE;
						movIntoReg(instrHeader.args[1], rightArg);
						IrIndex type = ir.getVirtReg(instrHeader.result).type;
						ExtraInstrArgs extra = { addUsers : false, argSize : instrHeader.argSize, type : type };
						InstrWithResult res = builder.emitInstr!LirAmd64Instr_shl(lirBlockIndex, extra, instrHeader.args[0], rightArg);
						recordIndex(instrIndex, res.instruction);
						recordIndex(instrHeader.result, res.result);
						break;
					case IrOpcode.load: emitLirInstr!LirAmd64Instr_load; break;
					case IrOpcode.store: emitLirInstr!LirAmd64Instr_store; break;
					case IrOpcode.conv:
						IrIndex typeFrom = getValueType(instrHeader.args[0], ir, *context);
						IrIndex typeTo = ir.getVirtReg(instrHeader.result).type;
						uint typeSizeFrom = context.types.typeSize(typeFrom);
						uint typeSizeTo = context.types.typeSize(typeTo);
						context.assertf(typeSizeTo <= typeSizeFrom,
							"Can't cast from %s bytes to %s bytes", typeSizeFrom, typeSizeTo);
						emitLirInstr!LirAmd64Instr_mov;
						break;

					case IrOpcode.block_exit_jump:
						builder.emitInstr!LirAmd64Instr_jmp(lirBlockIndex);
						break;

					case IrOpcode.block_exit_unary_branch:
						ExtraInstrArgs extra = {addUsers : false, cond : instrHeader.cond};
						IrIndex instruction = builder.emitInstr!LirAmd64Instr_un_branch(
							lirBlockIndex, extra, instrHeader.args);
						recordIndex(instrIndex, instruction);
						break;

					case IrOpcode.block_exit_binary_branch:
						ExtraInstrArgs extra = {addUsers : false, cond : instrHeader.cond};
						IrIndex instruction = builder.emitInstr!LirAmd64Instr_bin_branch(
							lirBlockIndex, extra, instrHeader.args);
						recordIndex(instrIndex, instruction);
						break;

					case IrOpcode.block_exit_return_void:
						builder.emitInstr!LirAmd64Instr_return(lirBlockIndex);
						break;

					case IrOpcode.block_exit_return_value:
						IrIndex result = lir.backendData.callingConvention.returnReg;
						IrIndex type = lir.backendData.returnType;
						result.physRegSize = typeToRegSize(type, context);
						ExtraInstrArgs extra = { addUsers : false, result : result };
						builder.emitInstr!LirAmd64Instr_mov(lirBlockIndex, extra, instrHeader.args);
						IrIndex instruction = builder.emitInstr!LirAmd64Instr_return(lirBlockIndex);
						recordIndex(instrIndex, instruction);
						break;

					default:
						context.internal_error("IrToLir unimplemented IR instr %s", cast(IrOpcode)instrHeader.op);
				}
			}
		}

		void fixArg(IrIndex instrIndex, ref IrIndex arg)
		{
			fixIndex(arg);
			builder.addUser(instrIndex, arg);
		}

		void fixInstrs(IrIndex blockIndex, ref IrBasicBlock lirBlock)
		{
			// replace old args with new args and add users
			foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; lirBlock.instructions(lir))
			{
				foreach(ref IrIndex arg; instrHeader.args)
				{
					fixArg(instrIndex, arg);
				}

				/// Cannot obtain address and store it in another address in one step
				if (instrHeader.op == Amd64Opcode.store && (instrHeader.args[1].isGlobal || instrHeader.args[1].isStackSlot))
				{
					// copy to temp register
					ExtraInstrArgs extra = { type : lir.getValueType(*context, instrHeader.args[1]) };
					InstrWithResult movInstr = builder.emitInstr!LirAmd64Instr_mov(
						extra, instrHeader.args[1]);
					builder.insertBeforeInstr(instrIndex, movInstr.instruction);
					// store temp to memory
					removeUser(*context, lir, instrIndex, instrHeader.args[1]);
					instrHeader.args[1] = movInstr.result;
					builder.addUser(instrIndex, movInstr.result);
				}
			}
		}

		void fixPhis(IrIndex blockIndex, ref IrBasicBlock lirBlock)
		{
			// fix phi args and add users
			foreach(IrIndex phiIndex, ref IrPhi phi; lirBlock.phis(lir))
			{
				foreach(size_t arg_i, ref IrPhiArg phiArg; phi.args(lir))
				{
					fixIndex(phiArg.basicBlock);
					fixIndex(phiArg.value);
					builder.addUser(phiIndex, phiArg.value);
				}
			}
		}

		foreach (IrIndex blockIndex, ref IrBasicBlock lirBlock; lir.blocks)
		{
			fixInstrs(blockIndex, lirBlock);
			fixPhis(blockIndex, lirBlock);
		}
	}
}
