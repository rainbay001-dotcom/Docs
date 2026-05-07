module attributes {dlti.target_system_spec = #dlti.target_system_spec<"NPU" : #hacc.target_device_spec<#dlti.dl_entry<"AI_CORE_COUNT", 24 : i32>, #dlti.dl_entry<"CUBE_CORE_COUNT", 24 : i32>, #dlti.dl_entry<"VECTOR_CORE_COUNT", 48 : i32>, #dlti.dl_entry<"UB_SIZE", 1572864 : i32>, #dlti.dl_entry<"L1_SIZE", 4194304 : i32>, #dlti.dl_entry<"L0A_SIZE", 524288 : i32>, #dlti.dl_entry<"L0B_SIZE", 524288 : i32>, #dlti.dl_entry<"L0C_SIZE", 1048576 : i32>, #dlti.dl_entry<"UB_ALIGN_SIZE", 256 : i32>, #dlti.dl_entry<"L1_ALIGN_SIZE", 256 : i32>, #dlti.dl_entry<"L0C_ALIGN_SIZE", 4096 : i32>, #dlti.dl_entry<"MINIMAL_D_CACHE_SIZE", 0 : i32>, #dlti.dl_entry<"MAXIMUM_D_CACHE_SIZE", 0 : i32>, #dlti.dl_entry<"ARCH", "dav-c220">>>, hacc.target = #hacc.target<"Ascend910B1">, hivm.module_core_type = #hivm.module_core_type<AIV>} {
  func.func @mask_kernel_cast(%arg0: memref<?xi8, #hivm.address_space<gm>>, %arg1: memref<?xi8, #hivm.address_space<gm>>, %arg2: memref<?xi32, #hivm.address_space<gm>> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32}, %arg3: memref<?xi32, #hivm.address_space<gm>> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32}, %arg4: memref<?xi32, #hivm.address_space<gm>> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32}, %arg5: memref<?xi32, #hivm.address_space<gm>> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32}, %arg6: memref<?xi8, #hivm.address_space<gm>> {tt.divisibility = 16 : i32, tt.tensor_kind = 1 : i32}, %arg7: i32, %arg8: i32, %arg9: i32, %arg10: i32, %arg11: i32, %arg12: i32) attributes {SyncBlockLockArgIdx = 0 : i64, WorkspaceArgIdx = 1 : i64, global_kernel = "local", hfusion.fusion_kind = #hfusion.fusion_kind<ANY_PB>, hivm.func_core_type = #hivm.func_core_type<AIV>, mix_mode = "aiv", parallel_mode = "simd"} {
    %c1 = arith.constant 1 : index
    %c0 = arith.constant 0 : index
    %c1024 = arith.constant 1024 : index
    %c61024_i64 = arith.constant 61024 : i64
    %c58976_i64 = arith.constant 58976 : i64
    %c54880_i64 = arith.constant 54880 : i64
    %c54784_i64 = arith.constant 54784 : i64
    %c52736_i64 = arith.constant 52736 : i64
    %c48640_i64 = arith.constant 48640 : i64
    %c44544_i64 = arith.constant 44544 : i64
    %c44416_i64 = arith.constant 44416 : i64
    %c42368_i64 = arith.constant 42368 : i64
    %c40320_i64 = arith.constant 40320 : i64
    %c40224_i64 = arith.constant 40224 : i64
    %c38176_i64 = arith.constant 38176 : i64
    %c38080_i64 = arith.constant 38080 : i64
    %c36032_i64 = arith.constant 36032 : i64
    %c35936_i64 = arith.constant 35936 : i64
    %c35872_i64 = arith.constant 35872 : i64
    %c27680_i64 = arith.constant 27680 : i64
    %c19488_i64 = arith.constant 19488 : i64
    %c18944_i64 = arith.constant 18944 : i64
    %c18688_i64 = arith.constant 18688 : i64
    %c18432_i64 = arith.constant 18432 : i64
    %c14336_i64 = arith.constant 14336 : i64
    %c19104_i64 = arith.constant 19104 : i64
    %c13312_i64 = arith.constant 13312 : i64
    %c9216_i64 = arith.constant 9216 : i64
    %c18976_i64 = arith.constant 18976 : i64
    %c5120_i64 = arith.constant 5120 : i64
    %c19360_i64 = arith.constant 19360 : i64
    %c4096_i64 = arith.constant 4096 : i64
    %c0_i64 = arith.constant 0 : i64
    %cst = arith.constant 0.000000e+00 : f16
    %cst_0 = arith.constant 0.000000e+00 : f32
    %c0_i32 = arith.constant 0 : i32
    %c19232_i64 = arith.constant 19232 : i64
    %0 = hivm.hir.pointer_cast(%c19232_i64) : memref<32x1xi32, #hivm.address_space<ub>>
    %collapse_shape = memref.collapse_shape %0 [[0, 1]] : memref<32x1xi32, #hivm.address_space<ub>> into memref<32xi32, #hivm.address_space<ub>>
    %1 = hivm.hir.pointer_cast(%c0_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    %2 = hivm.hir.pointer_cast(%c4096_i64) : memref<256xi32, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%0 : memref<32x1xi32, #hivm.address_space<ub>>) outs(%1 : memref<32x32xi32, #hivm.address_space<ub>>) temp_buffer(%2 : memref<256xi32, #hivm.address_space<ub>>) broadcast_dims = [1]
    %3 = hivm.hir.pointer_cast(%c19360_i64) : memref<1x32xi32, #hivm.address_space<ub>>
    %collapse_shape_1 = memref.collapse_shape %3 [[0, 1]] : memref<1x32xi32, #hivm.address_space<ub>> into memref<32xi32, #hivm.address_space<ub>>
    %4 = hivm.hir.pointer_cast(%c5120_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%3 : memref<1x32xi32, #hivm.address_space<ub>>) outs(%4 : memref<32x32xi32, #hivm.address_space<ub>>) broadcast_dims = [0]
    %5 = hivm.hir.pointer_cast(%c18976_i64) : memref<32x1xi32, #hivm.address_space<ub>>
    %collapse_shape_2 = memref.collapse_shape %5 [[0, 1]] : memref<32x1xi32, #hivm.address_space<ub>> into memref<32xi32, #hivm.address_space<ub>>
    %6 = hivm.hir.pointer_cast(%c9216_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    %7 = hivm.hir.pointer_cast(%c13312_i64) : memref<256xi32, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%5 : memref<32x1xi32, #hivm.address_space<ub>>) outs(%6 : memref<32x32xi32, #hivm.address_space<ub>>) temp_buffer(%7 : memref<256xi32, #hivm.address_space<ub>>) broadcast_dims = [1]
    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID0>]
    %8 = hivm.hir.pointer_cast(%c19104_i64) : memref<1x32xi32, #hivm.address_space<ub>>
    %collapse_shape_3 = memref.collapse_shape %8 [[0, 1]] : memref<1x32xi32, #hivm.address_space<ub>> into memref<32xi32, #hivm.address_space<ub>>
    %9 = hivm.hir.pointer_cast(%c14336_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%8 : memref<1x32xi32, #hivm.address_space<ub>>) outs(%9 : memref<32x32xi32, #hivm.address_space<ub>>) broadcast_dims = [0]
    %10 = hivm.hir.pointer_cast(%c18432_i64) : memref<32xi64, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%collapse_shape : memref<32xi32, #hivm.address_space<ub>>) outs(%10 : memref<32xi64, #hivm.address_space<ub>>)
    %11 = hivm.hir.pointer_cast(%c18688_i64) : memref<32xi64, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%collapse_shape_1 : memref<32xi32, #hivm.address_space<ub>>) outs(%11 : memref<32xi64, #hivm.address_space<ub>>)
    %12 = hivm.hir.pointer_cast(%c18944_i64) : memref<32xi1, #hivm.address_space<ub>>
    hivm.hir.vcmp ins(%collapse_shape_3, %c0_i32 : memref<32xi32, #hivm.address_space<ub>>, i32) outs(%12 : memref<32xi1, #hivm.address_space<ub>>)
    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID1>]
    %reinterpret_cast = memref.reinterpret_cast %arg2 to offset: [0], sizes: [32], strides: [1] : memref<?xi32, #hivm.address_space<gm>> to memref<32xi32, strided<[1]>, #hivm.address_space<gm>>
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID0>]
    hivm.hir.load ins(%reinterpret_cast : memref<32xi32, strided<[1]>, #hivm.address_space<gm>>) outs(%collapse_shape_2 : memref<32xi32, #hivm.address_space<ub>>) eviction_policy = <EvictFirst>
    %reinterpret_cast_4 = memref.reinterpret_cast %arg3 to offset: [0], sizes: [1, 32], strides: [32, 1] : memref<?xi32, #hivm.address_space<gm>> to memref<1x32xi32, #hivm.address_space<gm>>
    %collapse_shape_5 = memref.collapse_shape %reinterpret_cast_4 [[0, 1]] : memref<1x32xi32, #hivm.address_space<gm>> into memref<32xi32, #hivm.address_space<gm>>
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID1>]
    hivm.hir.load ins(%collapse_shape_5 : memref<32xi32, #hivm.address_space<gm>>) outs(%collapse_shape_3 : memref<32xi32, #hivm.address_space<ub>>) eviction_policy = <EvictFirst>
    %reinterpret_cast_6 = memref.reinterpret_cast %arg4 to offset: [0], sizes: [32], strides: [1] : memref<?xi32, #hivm.address_space<gm>> to memref<32xi32, strided<[1]>, #hivm.address_space<gm>>
    hivm.hir.load ins(%reinterpret_cast_6 : memref<32xi32, strided<[1]>, #hivm.address_space<gm>>) outs(%collapse_shape : memref<32xi32, #hivm.address_space<ub>>) eviction_policy = <EvictFirst>
    %reinterpret_cast_7 = memref.reinterpret_cast %arg5 to offset: [0], sizes: [1, 32], strides: [32, 1] : memref<?xi32, #hivm.address_space<gm>> to memref<1x32xi32, #hivm.address_space<gm>>
    %collapse_shape_8 = memref.collapse_shape %reinterpret_cast_7 [[0, 1]] : memref<1x32xi32, #hivm.address_space<gm>> into memref<32xi32, #hivm.address_space<gm>>
    hivm.hir.load ins(%collapse_shape_8 : memref<32xi32, #hivm.address_space<gm>>) outs(%collapse_shape_1 : memref<32xi32, #hivm.address_space<ub>>) eviction_policy = <EvictFirst>
    %reinterpret_cast_9 = memref.reinterpret_cast %arg6 to offset: [0], sizes: [32, 32], strides: [32, 1] : memref<?xi8, #hivm.address_space<gm>> to memref<32x32xi8, strided<[32, 1]>, #hivm.address_space<gm>>
    %collapse_shape_10 = memref.collapse_shape %1 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    %collapse_shape_11 = memref.collapse_shape %4 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    %13 = hivm.hir.pointer_cast(%c0_i64) : memref<1024xi1, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%collapse_shape_10, %collapse_shape_11 : memref<1024xi32, #hivm.address_space<ub>>, memref<1024xi32, #hivm.address_space<ub>>) outs(%13 : memref<1024xi1, #hivm.address_space<ub>>)
    %collapse_shape_12 = memref.collapse_shape %6 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    %collapse_shape_13 = memref.collapse_shape %9 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    %14 = hivm.hir.pointer_cast(%c9216_i64) : memref<1024xi1, #hivm.address_space<ub>>
    hivm.hir.vcmp ins(%collapse_shape_12, %collapse_shape_13 : memref<1024xi32, #hivm.address_space<ub>>, memref<1024xi32, #hivm.address_space<ub>>) outs(%14 : memref<1024xi1, #hivm.address_space<ub>>)
    %expand_shape = memref.expand_shape %10 [[0, 1]] output_shape [32, 1] : memref<32xi64, #hivm.address_space<ub>> into memref<32x1xi64, #hivm.address_space<ub>>
    %15 = hivm.hir.pointer_cast(%c19488_i64) : memref<32x32xi64, #hivm.address_space<ub>>
    %16 = hivm.hir.pointer_cast(%c27680_i64) : memref<0xi64, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%expand_shape : memref<32x1xi64, #hivm.address_space<ub>>) outs(%15 : memref<32x32xi64, #hivm.address_space<ub>>) temp_buffer(%16 : memref<0xi64, #hivm.address_space<ub>>) broadcast_dims = [1]
    %expand_shape_14 = memref.expand_shape %11 [[0, 1]] output_shape [1, 32] : memref<32xi64, #hivm.address_space<ub>> into memref<1x32xi64, #hivm.address_space<ub>>
    %17 = hivm.hir.pointer_cast(%c27680_i64) : memref<32x32xi64, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%expand_shape_14 : memref<1x32xi64, #hivm.address_space<ub>>) outs(%17 : memref<32x32xi64, #hivm.address_space<ub>>) broadcast_dims = [0]
    hivm.hir.set_flag[<PIPE_V>, <PIPE_S>, <EVENT_ID0>]
    %18 = hivm.hir.pointer_cast(%c35872_i64) : memref<32xf16, #hivm.address_space<ub>>
    %19 = hivm.hir.pointer_cast(%c35936_i64) : memref<48xf16, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%12 : memref<32xi1, #hivm.address_space<ub>>) outs(%18 : memref<32xf16, #hivm.address_space<ub>>) temp_buffer(%19 : memref<48xf16, #hivm.address_space<ub>>)
    %20 = hivm.hir.pointer_cast(%c36032_i64) : memref<1024xf16, #hivm.address_space<ub>>
    %21 = hivm.hir.pointer_cast(%c38080_i64) : memref<48xf16, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%13 : memref<1024xi1, #hivm.address_space<ub>>) outs(%20 : memref<1024xf16, #hivm.address_space<ub>>) temp_buffer(%21 : memref<48xf16, #hivm.address_space<ub>>)
    %22 = hivm.hir.pointer_cast(%c38176_i64) : memref<1024xf16, #hivm.address_space<ub>>
    %23 = hivm.hir.pointer_cast(%c40224_i64) : memref<48xf16, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%14 : memref<1024xi1, #hivm.address_space<ub>>) outs(%22 : memref<1024xf16, #hivm.address_space<ub>>) temp_buffer(%23 : memref<48xf16, #hivm.address_space<ub>>)
    %collapse_shape_15 = memref.collapse_shape %15 [[0, 1]] : memref<32x32xi64, #hivm.address_space<ub>> into memref<1024xi64, #hivm.address_space<ub>>
    %collapse_shape_16 = memref.collapse_shape %17 [[0, 1]] : memref<32x32xi64, #hivm.address_space<ub>> into memref<1024xi64, #hivm.address_space<ub>>
    %24 = hivm.hir.pointer_cast(%c19488_i64) : memref<1024xi8, #hivm.address_space<ub>>
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_S>, <EVENT_ID0>]
    scf.for %arg13 = %c0 to %c1024 step %c1 {
      %43 = memref.load %collapse_shape_15[%arg13] : memref<1024xi64, #hivm.address_space<ub>>
      %44 = memref.load %collapse_shape_16[%arg13] : memref<1024xi64, #hivm.address_space<ub>>
      %45 = arith.cmpi sle, %43, %44 : i64
      %46 = arith.extui %45 : i1 to i8
      memref.store %46, %24[%arg13] : memref<1024xi8, #hivm.address_space<ub>>
    }
    hivm.hir.set_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]
    %25 = hivm.hir.pointer_cast(%c40320_i64) : memref<1024xf16, #hivm.address_space<ub>>
    hivm.hir.wait_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]
    hivm.hir.vcast ins(%24 : memref<1024xi8, #hivm.address_space<ub>>) outs(%25 : memref<1024xf16, #hivm.address_space<ub>>)
    %26 = hivm.hir.pointer_cast(%c42368_i64) : memref<1024xf16, #hivm.address_space<ub>>
    hivm.hir.vbrc ins(%cst : f16) outs(%26 : memref<1024xf16, #hivm.address_space<ub>>)
    %27 = hivm.hir.pointer_cast(%c40320_i64) : memref<1024xi1, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%25, %26 : memref<1024xf16, #hivm.address_space<ub>>, memref<1024xf16, #hivm.address_space<ub>>) outs(%27 : memref<1024xi1, #hivm.address_space<ub>>) compare_mode = <ne>
    %28 = hivm.hir.pointer_cast(%c44416_i64) : memref<32xi32, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%18 : memref<32xf16, #hivm.address_space<ub>>) outs(%28 : memref<32xi32, #hivm.address_space<ub>>)
    %29 = hivm.hir.pointer_cast(%c44544_i64) : memref<1024xi32, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%20 : memref<1024xf16, #hivm.address_space<ub>>) outs(%29 : memref<1024xi32, #hivm.address_space<ub>>)
    %30 = hivm.hir.pointer_cast(%c48640_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    %collapse_shape_17 = memref.collapse_shape %30 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    hivm.hir.vcast ins(%22 : memref<1024xf16, #hivm.address_space<ub>>) outs(%collapse_shape_17 : memref<1024xi32, #hivm.address_space<ub>>)
    %31 = hivm.hir.pointer_cast(%c52736_i64) : memref<1024xf16, #hivm.address_space<ub>>
    %32 = hivm.hir.pointer_cast(%c54784_i64) : memref<48xf16, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%27 : memref<1024xi1, #hivm.address_space<ub>>) outs(%31 : memref<1024xf16, #hivm.address_space<ub>>) temp_buffer(%32 : memref<48xf16, #hivm.address_space<ub>>)
    %expand_shape_18 = memref.expand_shape %28 [[0, 1]] output_shape [1, 32] : memref<32xi32, #hivm.address_space<ub>> into memref<1x32xi32, #hivm.address_space<ub>>
    %33 = hivm.hir.pointer_cast(%c54880_i64) : memref<1024xi32, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%31 : memref<1024xf16, #hivm.address_space<ub>>) outs(%33 : memref<1024xi32, #hivm.address_space<ub>>)
    %34 = hivm.hir.pointer_cast(%c48640_i64) : memref<32x32xi32, #hivm.address_space<ub>>
    hivm.hir.vor ins(%30, %expand_shape_18 : memref<32x32xi32, #hivm.address_space<ub>>, memref<1x32xi32, #hivm.address_space<ub>>) outs(%34 : memref<32x32xi32, #hivm.address_space<ub>>) broadcast = [0]
    %collapse_shape_19 = memref.collapse_shape %34 [[0, 1]] : memref<32x32xi32, #hivm.address_space<ub>> into memref<1024xi32, #hivm.address_space<ub>>
    %35 = hivm.hir.pointer_cast(%c54880_i64) : memref<1024xi32, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vand ins(%33, %collapse_shape_19 : memref<1024xi32, #hivm.address_space<ub>>, memref<1024xi32, #hivm.address_space<ub>>) outs(%35 : memref<1024xi32, #hivm.address_space<ub>>)
    %36 = hivm.hir.pointer_cast(%c44544_i64) : memref<1024xi32, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vor ins(%35, %29 : memref<1024xi32, #hivm.address_space<ub>>, memref<1024xi32, #hivm.address_space<ub>>) outs(%36 : memref<1024xi32, #hivm.address_space<ub>>)
    %37 = hivm.hir.pointer_cast(%c44544_i64) : memref<1024xf32, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%36 : memref<1024xi32, #hivm.address_space<ub>>) outs(%37 : memref<1024xf32, #hivm.address_space<ub>>)
    %38 = hivm.hir.pointer_cast(%c44544_i64) : memref<1024xi1, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%37, %cst_0 : memref<1024xf32, #hivm.address_space<ub>>, f32) outs(%38 : memref<1024xi1, #hivm.address_space<ub>>)
    %39 = hivm.hir.pointer_cast(%c44544_i64) : memref<1024xi1, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vnot ins(%38 : memref<1024xi1, #hivm.address_space<ub>>) outs(%39 : memref<1024xi1, #hivm.address_space<ub>>)
    %40 = hivm.hir.pointer_cast(%c58976_i64) : memref<1024xf16, #hivm.address_space<ub>>
    %41 = hivm.hir.pointer_cast(%c61024_i64) : memref<48xf16, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%39 : memref<1024xi1, #hivm.address_space<ub>>) outs(%40 : memref<1024xf16, #hivm.address_space<ub>>) temp_buffer(%41 : memref<48xf16, #hivm.address_space<ub>>)
    %42 = hivm.hir.pointer_cast(%c58976_i64) : memref<1024xi8, #hivm.address_space<ub>>
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%40 : memref<1024xf16, #hivm.address_space<ub>>) outs(%42 : memref<1024xi8, #hivm.address_space<ub>>)
    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]
    %collapse_shape_20 = memref.collapse_shape %reinterpret_cast_9 [[0, 1]] : memref<32x32xi8, strided<[32, 1]>, #hivm.address_space<gm>> into memref<1024xi8, strided<[1]>, #hivm.address_space<gm>>
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]
    hivm.hir.store ins(%42 : memref<1024xi8, #hivm.address_space<ub>>) outs(%collapse_shape_20 : memref<1024xi8, strided<[1]>, #hivm.address_space<gm>>)
    return
  }
}
