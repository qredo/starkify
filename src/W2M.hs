{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE BlockArguments #-}

module W2M where

import Data.Bifunctor (first, second)
import Control.Applicative
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Bits
import Data.ByteString.Lazy qualified as BS
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable
import Data.List (stripPrefix)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text.Lazy (Text)
import Data.Text.Lazy qualified as T
import Data.Vector (Vector, (!))
import Data.Vector qualified as V
import Data.Word (Word8, Word32)
import GHC.Natural (Natural)
import Language.Wasm.Structure qualified as W

import MASM qualified as M
import MASM.Interpreter (toFakeW64, FakeW64 (..))
import Tools (dfs)
import Validation
import WASI qualified

type WasmAddr = Natural
type MasmAddr = Word32
type LocalAddrs = Map WasmAddr (W.ValueType, [MasmAddr])
type FunName = Text
type Function = Either W.Import W.Function

-- Note: Wasm modules may fail to compile if they contain > 2^29 functions.

toMASM :: W.Module -> V M.Module
toMASM m = do
  -- TODO: don't throw away main's type, we might want to check it and inform how the program can be called?
  globalsInit <- inContext GlobalsInit getGlobalsInit
  datasInit <- inContext DatasInit getDatasInit
  when (null entryFunctions) $ error "No start function or 'main' function found in WASM module, cannot proceed."
  procs <- catMaybes <$> traverse (\ idx -> fmap (procName idx,) <$> fun2MASM idx (allFunctions ! idx)) (toList sortedFunctions)
  methodInits <- sequence [ concat <$> traverse translateGlobals (WASI.init method) | (_, Left method) <- procs ]
  let (procNames, procs') = unzip $ fmap (second translateProc) procs

  M.Module ["std::sys", "std::math::u64"]
    <$> (zip procNames <$> sequence procs')
    -- TODO: Do we need to perform stack cleanup even if proc_exit is invoked?
    <*> return (M.Program (globalsInit ++ datasInit ++ concat methodInits ++ fmap (M.Exec . procName) entryFunctions))

  where wasiGlobals :: [Text]
        wasiGlobals = [ g | (Left (Just method)) <- first wasiImport <$> fmap (allFunctions !) (toList sortedFunctions)
                          , g <- WASI.globals method ]

        wasiImport :: W.Import -> Maybe WASI.Method
        wasiImport (W.Import module' name _) = Map.lookup name =<< Map.lookup module' WASI.library

        globalsAddrMap :: Vector MasmAddr
        wasiGlobalsAddrMap :: Map Text MasmAddr
        branchCounter :: MasmAddr
        memBeginning :: MasmAddr
        branchCounter = 0
        (wasiGlobalsAddrMap, memBeginning') = first Map.fromList $ foldl' f ([], 1) wasiGlobals
          where f (xs, n) name = (xs ++ [(name, n)], n+1)
        (globalsAddrMap, memBeginning) = first V.fromList $ foldl' f ([], memBeginning') (W.globals m)
          where f (xs, n) globl_i =
                  let ncells = case W.globalType globl_i of
                                 W.Const t -> numCells t
                                 W.Mut   t -> numCells t
                  in (xs ++ [n], n+ncells)

        translateGlobals :: WASI.Instruction -> V [M.Instruction]
        translateGlobals (WASI.M i) = pure [i]
        translateGlobals (WASI.Load n) = maybe (badNamedGlobalRef n) (\ a -> pure [M.MemLoad (Just a)]) (Map.lookup n wasiGlobalsAddrMap)
        translateGlobals (WASI.Store n) = maybe (badNamedGlobalRef n) (\ a -> pure [M.MemStore (Just a), M.Drop]) (Map.lookup n wasiGlobalsAddrMap)

        translateProc :: Either WASI.Method M.Proc -> V M.Proc
        translateProc (Left method) = M.Proc (WASI.locals method) . concat <$> traverse translateGlobals (WASI.body method)
        translateProc (Right p) = pure p

        callGraph :: Map Int (Set Int)
        callGraph = Map.fromListWith (<>)
          [ (caller, Set.singleton (fromIntegral callee))
          | (caller, Right (W.Function {body})) <- V.toList $ V.indexed allFunctions
          , W.Call callee <- body
          ]
        -- enumerate x = x : concatMap enumerate [ y | y <- maybe [] Set.toList (Map.lookup x callGraph) ]

        -- Each compiler has a different convention for exporting the main function, and the
        -- https://www.w3.org/TR/wasm-core-1/#start-function is something different. Since we don't
        -- currently pass input to the main function, we can proceed if either is present (and we
        -- should use both if both are present).
        entryFunctions = fromIntegral <$> nubOrd (maybeToList startFunIdx <> maybeToList mainFunIdx)

        -- An export with an empty string is considered to be a "default export".
        -- (https://github.com/bytecodealliance/wasmtime/blob/b0939f66267dc99b56f59fdb7c1db4fce2f578c6/crates/wasmtime/src/linker.rs#L1187)
        mainFunIdx = lookup "main" exportedFunctions
                 <|> lookup "_start" exportedFunctions
                 <|> lookup "" exportedFunctions

        exportedFunctions :: [(FunName, W.FuncIndex)]
        exportedFunctions = [(name, idx) | (W.Export name (W.ExportFunc idx)) <- W.exports m]

        startFunIdx
          | Just (W.StartFunction k) <- W.start m = Just k
          | otherwise = Nothing

        -- Miden requires procedures to be defined before any execs that reference them.
        sortedFunctions :: [Int]
        sortedFunctions = reverse $ nubOrd $ concatMap (`dfs` callGraph) entryFunctions

        numCells :: W.ValueType -> Word32
        numCells t = case t of
          W.I32 -> 1
          W.I64 -> 2
          _ -> error "numCells called on non integer value type"

        getDatasInit :: V [M.Instruction]
        getDatasInit = concat <$> traverse getDataInit (W.datas m)

        getDataInit :: W.DataSegment -> V [M.Instruction]
        getDataInit (W.DataSegment 0 offset_wexpr bytes) = do
          offset_mexpr <- translateInstrs mempty offset_wexpr
          pure $ offset_mexpr ++
                 [ M.Push 4, M.IDiv             -- [offset_bytes/4, ...]
                 , M.Push memBeginning, M.IAdd  -- [offset_bytes/4+memBeginning, ...] =
                 ] ++                           -- [addr_u32, ...]
                 writeW32s (BS.unpack bytes) ++ -- [addr_u32+len(bytes)/4, ...]
                 [ M.Drop ]                     -- [...]
        getDataInit _ = badNoMultipleMem

        getGlobalsInit :: V [M.Instruction]
        getGlobalsInit = concat <$> traverse getGlobalInit (zip [0..] (W.globals m))

        getGlobalInit :: (Int, W.Global) -> V [M.Instruction]
        getGlobalInit (k, g) =
          translateInstrs mempty (W.initializer g ++ [W.SetGlobal $ fromIntegral k])

        getGlobalTy k
          | fromIntegral k < length (W.globals m) = case t of
              W.I32 -> W.I32
              W.I64 -> W.I64
              _     -> error "unsupported global type"
          | otherwise = error "getGlobalTy: index too large"

            where t = case W.globalType (W.globals m !! fromIntegral k) of
                        W.Const ct -> ct
                        W.Mut mt -> mt

        -- "Functions are referenced through function indices, starting with the smallest index not referencing a function import."
        --                                              (https://webassembly.github.io/spec/core/syntax/modules.html#syntax-module)
        -- "Definitions are referenced with zero-based indices."
        --                                             (https://webassembly.github.io/spec/core/syntax/modules.html#syntax-funcidx)
        allFunctions :: Vector Function
        allFunctions = V.fromList $
          [ Left f | f@(W.Import _ _ (W.ImportFunc _)) <- W.imports m ] <>
          [ Right f | f <- W.functions m ]

        types :: Vector W.FuncType
        types = V.fromList $ W.types m

        emptyFunctions :: Set Int
        emptyFunctions = Set.fromList $ V.toList $ V.findIndices emptyF allFunctions
         where emptyF (Right (W.Function _ _ [])) = True
               emptyF _ = False

        functionType :: Function -> W.FuncType
        -- Function indices are checked by the wasm library and will always be in range.
        functionType (Left (W.Import _ _ (W.ImportFunc idx))) = types ! fromIntegral idx
        functionType (Right (W.Function {funcType})) = types ! fromIntegral funcType

        procName :: Int -> M.ProcName
        procName i = "f" <> T.pack (show i)

        branch :: Natural -> V [M.Instruction]
        branch idx = do
          -- Clean up the stack.
          stack <- stackFromBlockN idx
          t <- blockNBranchType idx
          let resultStackSize = sum $ fmap typeStackSize t
              drop' = case resultStackSize of
                        0 -> [M.Drop]
                        1 -> [M.Swap 1, M.Drop]
                        _ -> [M.MoveUp (fromIntegral resultStackSize), M.Drop]
          if resultStackSize >= M.accessibleStackDepth
            then bad $ BlockResultTooLarge resultStackSize
            else pure $ concat (replicate (length stack - resultStackSize) drop') <>
                        -- Set the branch counter.
                        [ M.Push (fromIntegral idx + 1)
                        , M.MemStore (Just branchCounter)
                        , M.Drop
                        ]
          where typeStackSize W.I32 = 1
                typeStackSize W.I64 = 2

        continue :: [M.Instruction] -> [M.Instruction]
        continue is =
          [ M.MemLoad (Just branchCounter)
          , M.Eq (Just 1)
          , M.If [ M.Push 0
                 , M.MemStore (Just branchCounter)
                 , M.Drop
                 ] []
          , M.MemLoad (Just branchCounter)
          , M.NEq (Just 0)
          , M.If [ M.MemLoad (Just branchCounter)
                 , M.Sub (Just 1)
                 , M.MemStore (Just branchCounter)
                 , M.Drop
                 ]
                 is
          ]

        blockResultType :: W.BlockType -> W.ResultType
        blockResultType (W.Inline Nothing) = []
        blockResultType (W.Inline (Just t')) = [t']
        blockResultType (W.TypeIndex ti) = W.results $ types ! fromIntegral ti

        blockParamsType :: W.BlockType -> W.ParamsType
        blockParamsType (W.Inline _) = []
        blockParamsType (W.TypeIndex ti) = W.params $ types ! fromIntegral ti

        blockNBranchType :: Natural -> V W.ResultType
        blockNBranchType = asks . f
          where f 0 (InBlock Block t _:_) = blockResultType t
                f 0 (InBlock Loop t _:_) = blockParamsType t
                f n (InBlock _ _ _:ctxs) = f (n-1) ctxs
                f _ (InFunction idx:_) = W.results (functionType (allFunctions ! idx))
                f n (_:ctxs) = f n ctxs

        stackFromBlockN :: Natural -> V W.ResultType
        stackFromBlockN n = do
          stack <- get
          asks ((stack <>) . f n)
          where f 0 _ = []
                f n' (InBlock _ _ s:ctxs) = if n' == 1 then s else s <> f (n'-1) ctxs
                f _ (InFunction _:_) = []
                f n' (_:ctxs) = f n' ctxs

        fun2MASM :: Int -> Function -> V (Maybe (Either WASI.Method M.Proc))
        fun2MASM _   (Left i) = inContext Import $ maybe (badImport i) (pure . Just . Left) (wasiImport i)
        fun2MASM _   (Right (W.Function _ _         [])) = return Nothing
        -- TODO: Add back function name to context.
        fun2MASM idx (Right (W.Function typ localsTys body)) = inContext (InFunction idx) $ do
          let wasm_args = W.params (types ! fromIntegral typ)
              wasm_locals = localsTys

              localAddrMap :: LocalAddrs
              (localAddrMap, nlocalCells) =
                foldl' (\(addrs, cnt) (k, ty) -> case ty of
                           W.I32 -> (Map.insert k (W.I32, [cnt]) addrs, cnt+1)
                           W.I64 -> (Map.insert k (W.I64, [cnt, cnt+1]) addrs, cnt+2)
                           _     -> error "localAddrMap: floating point local var?"
                       )
                       (Map.empty, 0)
                       (zip [0..] (wasm_args ++ wasm_locals))
              -- the function starts by populating the first nargs local vars
              -- with the topmost nargs values on the stack, removing them from
              -- the stack as it goes. it assumes the value for the first arg
              -- was pushed first, etc, with the value for the last argument
              -- being pushed last and therefore popped first.
              prelude = reverse $ concat
                [ case Map.lookup (fromIntegral k) localAddrMap of
                    Just (_t, is) -> concat [ [ M.Drop, M.LocStore i ] | i <- is ]
                    -- TODO: Add back function name to error.
                    _ -> error ("impossible: prelude of procedure " ++ show idx ++ ", local variable " ++ show k ++ " not found?!")
                | k <- [0..(length wasm_args - 1)]
                ]
          instrs <- translateInstrs localAddrMap body
          return $ Just (Right (M.Proc (fromIntegral nlocalCells) (prelude ++ instrs)))

        translateInstrs :: LocalAddrs -> W.Expression -> V [M.Instruction]
        translateInstrs _ [] = pure []
        translateInstrs a (W.Block t body:is) = do
          stack <- get
          body' <- inContext (InBlock Block t stack) (put (blockParamsType t) >> translateInstrs a body)
          put (blockResultType t <> stack)
          is' <- continue <$> translateInstrs a is
          pure $ body' <> is'
        translateInstrs a (W.Loop t body:is) = do
          stack <- get
          body' <- inContext (InBlock Loop t stack) (put (blockParamsType t) >> translateInstrs a body)
          put (blockResultType t <> stack)
          is' <- continue <$> translateInstrs a is
          pure $ [M.Push 1, M.While (body' <> continueLoop)] <> is'
          where continueLoop =
                  [ M.MemLoad (Just branchCounter)
                  , M.Eq (Just 1)
                  , M.Dup 0
                  , M.If [ M.Push 0
                         , M.MemStore (Just branchCounter)
                         , M.Drop
                         ] []
                  ]
        translateInstrs a (W.If t tb fb:is) = do
          stack <- get
          tb' <- inContext (InBlock If t stack) (put params >> translateInstrs a tb)
          fb' <- inContext (InBlock If t stack) (put params >> translateInstrs a fb)
          put (blockResultType t <> stack)
          is' <- continue <$> translateInstrs a is
          pure $ case (tb', fb') of
                   ([], []) -> is'
                   ([], _) -> [M.Eq (Just 0), M.If fb' tb'] <> is'
                   (_, _) -> [M.NEq (Just 0), M.If tb' fb'] <> is'
          where params = blockParamsType t
        translateInstrs _ (W.Br idx:_) = branch idx
        translateInstrs a (W.BrIf idx:is) = do
          is' <- translateInstrs a is
          br <- branch idx
          pure [M.NEq (Just 0), M.If br is']
        -- Note: br_table could save 2 cycles by not duping and dropping in the final case (for br_tables with 1 or more cases).
        translateInstrs _ (W.BrTable cases defaultIdx:_) = brTable 0 cases
          where brTable _ [] = (M.Drop :) <$> branch defaultIdx
                brTable i (idx:idxs) = do
                  br <- branch idx
                  br' <- brTable (i+1) idxs
                  pure [M.Dup 0, M.Eq (Just i), M.If (M.Drop : br) br']
        translateInstrs _ (W.Return:_) = branch . fromIntegral =<< blockDepth
        translateInstrs a (i:is) = (<>) <$> translateInstr a i <*> translateInstrs a is

        translateInstr :: LocalAddrs -> W.Instruction Natural -> V [M.Instruction]
        translateInstr _ (W.Call idx) = let i = fromIntegral idx in
          case functionType (allFunctions ! i) of
            W.FuncType params res -> do
              params' <- checkTypes params
              res' <- checkTypes res
              let instrs =
                    if Set.member i emptyFunctions
                      then concat [ if t == W.I64 then [ M.Drop, M.Drop ] else [ M.Drop ]
                                  | t <- params'
                                  ]
                      else [M.Exec $ procName i]
              typed (reverse params') res' instrs
        translateInstr _ (W.I32Const w32) = typed [] [W.I32] [M.Push w32]
        translateInstr _ (W.IBinOp bitsz op) = translateIBinOp bitsz op
        translateInstr _ W.I32Eqz = typed [W.I32] [W.I32] [M.IEq (Just 0)]
        translateInstr _ (W.IRelOp bitsz op) = translateIRelOp bitsz op
        translateInstr _ W.Select = typed [W.I32, W.I32, W.I32] [W.I32]
          [M.CDrop]
        translateInstr _ (W.I32Load (W.MemArg offset _align)) = typed [W.I32] [W.I32]
            -- assumes byte_addr is divisible by 4 and ignores remainder... hopefully it's always 0?
                   [ M.Push 4
                   , M.IDiv
                   , M.Push (fromIntegral offset `div` 4)
                   , M.IAdd
                   , M.Push memBeginning
                   , M.IAdd
                   , M.MemLoad Nothing
                   ]
        translateInstr _ (W.I32Store (W.MemArg offset _align)) =
          -- we need to turn [val, byte_addr, ...] of wasm into [u32_addr, val, ...]
            typed [W.I32, W.I32] []
            -- assumes byte_addr is divisible by 4 and ignores remainder... hopefully it's always 0?
                   [ M.Swap 1
                   , M.Push 4
                   , M.IDiv
                   , M.Push (fromIntegral offset `div` 4)
                   , M.IAdd
                   , M.Push memBeginning
                   , M.IAdd
                   , M.MemStore Nothing
                   , M.Drop
                   ]
        translateInstr _ (W.I32Load8U (W.MemArg offset _align)) =
            typed [W.I32] [W.I32]
                   [ M.Push (fromIntegral offset) -- [offset, byte_addr, ...]
                   , M.IAdd                       -- [byte_addr+offset, ...]
                   , M.IDivMod (Just 4)           -- [r, q, ...]
                                                  -- where byte_addr+offset = 4*q + r
                   , M.Swap 1                     -- [q, r, ...]
                   , M.Push memBeginning
                   , M.IAdd                       -- [memBeginning+q, r, ...]
                   , M.MemLoad Nothing            -- [v, r, ...]
                   , M.Swap 1                     -- [r, v, ...]
                   -- we have an i32 (v), but we need just the 8 bits between spots 8*r and 8*r+7
                   -- so we AND with the right mask and shift the result right by 8*r bits.
                   -- (v & mask) << (8*r) gives us (as an i32) the value of the 8-bits starting
                   -- at position 8*r. e.g (with lowest bits on the left):
                   -- v    = xxxxxxxx|abcdefgh|xxxxxxxx|xxxxxxxx
                   -- mask = 00000000|11111111|00000000|00000000
                   -- and  = 00000000|abcdefgh|00000000|00000000
                   -- res  = abcdefgh|00000000|00000000|00000000
                   -- note: 11111111 is 255
                   , M.Push 8, M.IMul     -- [8*r, v, ...]
                   , M.Swap 1, M.Dup 1    -- [8*r, v, 8*r, ...]
                   , M.Push 255, M.Swap 1 -- [8*r, 255, v, 8*r...]
                   , M.IShL               -- [mask, v, 8*r, ...]
                   , M.IAnd               -- [and, 8*r, ...]
                   , M.Swap 1, M.IShR     -- [res, ...]
                   ]
        translateInstr a (W.I32Load8S mem) = do
          loadInstrs <- translateInstr a (W.I32Load8U mem)
          sigInstrs <- typed [W.I32] [W.I32]         -- [v, ...]
                   [ M.Dup 0                         -- [v, v, ...]
                   , M.Push 128, M.IGte              -- [v >= 128, v, ...]
                   , M.If                            -- [v, ...]
                       [ M.Push 255, M.Swap 1        -- [v, 255, ...]
                       , M.ISub, M.Push 1, M.IAdd    -- [255 - v + 1, ...]
                       , M.Push 4294967295           -- [4294967295, 255 - v + 1, ...]
                       , M.Swap 1, M.ISub            -- [4294967295 - (255 - v + 1), ...]
                       , M.Push 1, M.IAdd            -- [4294967295 - (255 - v + 1) + 1, ...]
                       ]
                       [] -- if the 32 bits of v encode a positive 8 bits number, nothing to do
                   ]
          pure $ loadInstrs <> sigInstrs
        translateInstr _ (W.I32Store8 (W.MemArg offset _align)) =
          -- we have an 8-bit value stored in an i32, e.g (lowest on the left):
          -- i   = abcdefgh|00000000|00000000|00000000
          -- there's an i32 value stored at addr q, e.g:
          -- v   = xxxxxxxx|xxxxxxxx|xxxxxxxx|xxxxxxxx
          -- and we want to update the 8*r to 8*r+7 bits of v with
          -- the first 8 bits of i, so in the example ending with:
          -- res = xxxxxxxx|abcdefgh|xxxxxxxx|xxxxxxxx
          -- we get there by shifting i by 8*r bits to the "left":
          -- i'  = 00000000|abcdefgh|00000000|00000000
          -- setting free the relevant bits in v:
          -- v'  = xxxxxxxx|00000000|xxxxxxxx|xxxxxxxx
          -- and storing v' | i'
            typed [W.I32, W.I32] []
                   [ M.Swap 1                     -- [byte_addr, i, ...]
                   , M.Push (fromIntegral offset) -- [offset, byte_addr, i, ...]
                   , M.IAdd                       -- [byte_addr+offset, i, ...]
                   , M.IDivMod (Just 4)           -- [r, q, i, ...]
                                                  -- where byte_addr+offset = 4*q + r
                   , M.Push 8, M.IMul             -- [8*r, q, i, ...]
                   , M.Dup 0                      -- [8*r, 8*r, q, i, ...]
                   , M.Push 255, M.Swap 1         -- [8*r, 255, 8*r, q, i, ...]
                   , M.IShL, M.INot               -- [mask, 8*r, q, i, ...]
                   , M.Swap 2                     -- [q, 8*r, mask, i, ...]
                   , M.Push memBeginning
                   , M.IAdd                       -- [memBeginning+q, 8*r, mask, i, ...]
                   , M.Dup 0                      -- [memBeginning+q, memBeginning+q, 8*r, mask, i, ...]
                   , M.MemLoad Nothing            -- [v, memBeginning+q, 8*r, mask, i, ...]
                   , M.Swap 1, M.Swap 3           -- [mask, v, 8*r, memBeginning+q, i, ...]
                   , M.IAnd                       -- [v', 8*r, memBeginning+q, i, ...]
                   , M.Swap 3                     -- [i, 8*r, memBeginning+q, v', ...]
                   , M.Swap 1                     -- [8*r, i, memBeginning+q, v', ...]
                   , M.IShL                       -- [i', memBeginning+q, v', ...]
                   , M.Swap 1, M.Swap 2           -- [v', i', memBeginning+q, ...]
                   , M.IOr                        -- [final_val, memBeginning+q, ...]
                   , M.Swap 1                     -- [memBeginning+q, final_val, ...]
                   , M.MemStore Nothing           -- [final_val, ...]
                   , M.Drop                       -- [...]
                   ]
        translateInstr _ (W.I32Load16U (W.MemArg offset _align)) = typed [W.I32] [W.I32]
                   [ M.Push (fromIntegral offset) -- [offset, byte_addr, ...]
                   , M.IAdd                       -- [byte_addr+offset, ...]
                   , M.IDivMod (Just 4)           -- [r, q, ...]
                                                  -- where byte_addr+offset = 4*q + r
                   , M.Swap 1                     -- [q, r, ...]
                   , M.Push memBeginning
                   , M.IAdd                       -- [memBeginning+q, r, ...]
                   , M.MemLoad Nothing            -- [v, r, ...]
                   , M.Swap 1                     -- [r, v, ...]
                   -- we have an i32 (v), but we need just the 16 bits between spots 8*r and 8*r+15
                   -- so we AND with the right mask and shift the result right by 8*r bits.
                   -- (v & mask) << (8*r) gives us (as an i32) the value of the 16-bits starting
                   -- at position 8*r. e.g (with lowest bits on the left):
                   -- v    = xxxxxxxx|abcdefgh|ijklmnop|xxxxxxxx
                   -- mask = 00000000|11111111|11111111|00000000
                   -- and  = 00000000|abcdefgh|ijklmnop|00000000
                   -- res  = abcdefgh|ijklmnop|00000000|00000000
                   -- note: 11111111|11111111 is 65535
                   , M.Push 8, M.IMul       -- [8*r, v, ...]
                   , M.Swap 1, M.Dup 1      -- [8*r, v, 8*r, ...]
                   , M.Push 65535, M.Swap 1 -- [8*r, 65535, v, 8*r...]
                   , M.IShL                 -- [mask, v, 8*r, ...]
                   , M.IAnd                 -- [and, 8*r, ...]
                   , M.Swap 1, M.IShR       -- [res, ...]
                   ]
        translateInstr _ (W.I32Store16 (W.MemArg offset _align))
          | mod offset 4 == 3 = error "offset = 3!"
          | otherwise = typed [W.I32, W.I32] []
                   [ M.Swap 1                     -- [byte_addr, i, ...]
                   , M.Push (fromIntegral offset) -- [offset, byte_addr, i, ...]
                   , M.IAdd                       -- [byte_addr+offset, i, ...]
                   , M.IDivMod (Just 4)           -- [r, q, i, ...]
                                                  -- where byte_addr+offset = 4*q + r
                   , M.Push 8, M.IMul             -- [8*r, q, i, ...]
                   , M.Dup 0                      -- [8*r, 8*r, q, i, ...]
                   , M.Push 65535, M.Swap 1       -- [8*r, 65535, 8*r, q, i, ...]
                   , M.IShL, M.INot               -- [mask, 8*r, q, i, ...]
                   , M.Swap 2                     -- [q, 8*r, mask, i, ...]
                   , M.Push memBeginning
                   , M.IAdd                       -- [memBeginning+q, 8*r, mask, i, ...]
                   , M.Dup 0                      -- [memBeginning+q, memBeginning+q, 8*r, mask, i, ...]
                   , M.MemLoad Nothing            -- [v, memBeginning+q, 8*r, mask, i, ...]
                   , M.Swap 1, M.Swap 3           -- [mask, v, 8*r, memBeginning+q, i, ...]
                   , M.IAnd                       -- [v', 8*r, memBeginning+q, i, ...]
                   , M.Swap 3                     -- [i, 8*r, memBeginning+q, v', ...]
                   , M.Swap 1                     -- [8*r, i, memBeginning+q, v', ...]
                   , M.IShL                       -- [i', memBeginning+q, v', ...]
                   , M.Swap 1, M.Swap 2           -- [v', i', memBeginning+q, ...]
                   , M.IOr                        -- [final_val, memBeginning+q, ...]
                   , M.Swap 1                     -- [memBeginning+q, final_val, ...]
                   , M.MemStore Nothing           -- [final_val, ...]
                   , M.Drop                       -- [...]
                   ]
        -- locals
        translateInstr localAddrs (W.GetLocal k) = case Map.lookup k localAddrs of
          Just (loct, is) -> typed [] [loct] (map M.LocLoad is)
          _ -> error ("impossible: local variable " ++ show k ++ " not found?!")

        translateInstr localAddrs (W.SetLocal k) = case Map.lookup k localAddrs of
          Just (loct, as) -> typed [loct] []
              ( concat
                  [ [ M.LocStore a
                    , M.Drop
                    ]
                  | a <- reverse as
                  ]
              )
          _ -> error ("impossible: local variable " ++ show k ++ " not found?!")
        translateInstr localAddrs (W.TeeLocal k) =
          (<>) <$> translateInstr localAddrs (W.SetLocal k)
               <*> translateInstr localAddrs (W.GetLocal k)

        -- globals
        translateInstr _ (W.GetGlobal k) = case getGlobalTy k of
          W.I32 -> typed [] [W.I32]
              [ M.MemLoad . Just $ globalsAddrMap V.! fromIntegral k]
          W.I64 -> typed [] [W.I64]
              [ M.MemLoad . Just $ globalsAddrMap V.! fromIntegral k
              , M.MemLoad . Just $ (globalsAddrMap V.! fromIntegral k) + 1
              ]
          t -> error $ "unsupported type: " ++ show t
        translateInstr _ (W.SetGlobal k) = case getGlobalTy k of
          W.I32 -> typed [W.I32] []
              [ M.MemStore . Just $ globalsAddrMap V.! fromIntegral k
              , M.Drop
              ]
          W.I64 -> typed [W.I64] []
              [ M.MemStore . Just $ (globalsAddrMap V.! fromIntegral k) + 1
              , M.Drop
              , M.MemStore . Just $ (globalsAddrMap V.! fromIntegral k)
              , M.Drop
              ]
          t -> error $ "unsupported type: " ++ show t

        -- https://maticnetwork.github.io/miden/user_docs/stdlib/math/u64.html
        -- 64 bits integers are emulated by separating the high and low 32 bits.
        translateInstr _ (W.I64Const k) = typed [] [W.I64]
            [ M.Push k_lo
            , M.Push k_hi
            ]
          where FakeW64 k_hi k_lo = toFakeW64 k
        translateInstr _ (W.I64Load (W.MemArg offset _align))
          | mod offset 4 /= 0 = error "i64 load"
          | otherwise         =
          -- we need to turn [byte_addr, ...] of wasm into
          -- [u32_addr, ...] for masm, and then call mem_load
          -- twice (once at u32_addr, once at u32_addr+1)
          -- to get lo and hi 32 bits of i64 value respectively.
          --
          -- u32_addr = (byte_addr / 4) + (offset / 4) + memBeginning
          typed [W.I32] [W.I64]
              [ M.Push 4, M.IDiv
              , M.Push (fromIntegral offset `div` 4)
              , M.IAdd
              , M.Push memBeginning, M.IAdd -- [addr, ...]
              , M.Dup 0 -- [addr, addr, ...]
              , M.MemLoad Nothing -- [lo, addr, ...]
              , M.Swap 1 -- [addr, lo, ...]
              , M.Push 1, M.IAdd -- [addr+1, lo, ...]
              , M.MemLoad Nothing -- [hi, lo, ...]
              ]
        translateInstr _ (W.I64Store (W.MemArg offset _align))
          | mod offset 4 /= 0 = error "i64 store"
          | otherwise   =
          -- we need to turn [val_hi, val_low, byte_addr, ...] of wasm into
          -- [u32_addr, val64_hi, val64_low, ...] for masm,
          -- and the call mem_store twice
          -- (once at u32_addr, once at u32_addr+1)
          -- to get hi and lo 32 bits of i64 value.
          typed [W.I64, W.I32] []
              [ M.Swap 1, M.Swap 2 -- [byte_addr, hi, lo, ...]
              , M.Push 4, M.IDiv
              , M.Push (fromIntegral offset `div` 4)
              , M.IAdd
              , M.Push memBeginning
              , M.IAdd -- [addr, hi, lo, ...]
              , M.Dup 0 -- [addr, addr, hi, lo, ...]
              , M.Swap 2, M.Swap 1 -- [addr, hi, addr, lo, ...]
              , M.Push 1, M.IAdd -- [addr+1, hi, addr, lo, ...]
              , M.MemStore Nothing -- [hi, addr, lo, ...]
              , M.Drop -- [addr, lo, ...]
              , M.MemStore Nothing -- [lo, ...]
              , M.Drop -- [...]
              ]
        translateInstr _ (W.I64Store8 (W.MemArg offset _align)) =
          -- we have an 8-bit value stored in an i64 (two 32 bits in Miden land),
          -- e.g (lowest on the left):
          -- i   = abcdefgh|00000000|00000000|00000000||00000000|00000000|00000000|00000000
          -- there's an i64 value stored at addr q, e.g:
          -- v   = xxxxxxxx|xxxxxxxx|xxxxxxxx|xxxxxxxx||xxxxxxxx|xxxxxxxx|xxxxxxxx|xxxxxxxx
          -- and we want to update the 8*r to 8*r+7 bits of v with
          -- the first 8 bits of i, so in the example ending with:
          -- res = xxxxxxxx|xxxxxxxx|xxxxxxxx|xxxxxxxx||xxxxxxxx|abcdefgh|xxxxxxxx|xxxxxxxx
          -- we get there by shifting i by 8*r bits to the "left":
          -- i'  = 00000000|00000000|00000000|00000000||00000000|abcdefgh|00000000|00000000
          -- setting free the relevant bits in v:
          -- v'  = xxxxxxxx|xxxxxxxx|xxxxxxxx|xxxxxxxx||xxxxxxxx|00000000|xxxxxxxx|xxxxxxxx
          -- and storing v' | i'
            typed [W.I32, W.I64] []               -- [i_hi, i_lo, byte_addr, ...]
                   [ M.Swap 1 , M.Swap 2          -- [byte_addr, i_hi, i_lo, ...]
                   , M.Push (fromIntegral offset) -- [offset, byte_addr, i_hi, i_lo, ...]
                   , M.IAdd                       -- [byte_addr+offset, i_hi, i_lo, ...]
                   , M.IDivMod (Just 4)           -- [r, q, i_hi, i_lo, ...]
                                                  -- where byte_addr+offset = 4*q + r
                   , M.Push 8, M.IMul             -- [8*r, q, i_hi, i_lo, ...]
                   , M.Dup 0                      -- [8*r, 8*r, q, i_hi, i_lo, ...]
                   , M.Push 255, M.Swap 1         -- [8*r, 255, 8*r, q, i_hi, i_lo, ...]
                   , M.IShL, M.INot               -- [mask_hi, mask_lo, 8*r, q, i_hi, i_lo, ...]
                   , M.Swap 2                     -- [8*r, mask_lo, mask_hi, q, i_hi, i_lo, ...]
                   , M.Swap 1                     -- [mask_lo, 8*r, mask_hi, q, i_hi, i_lo, ...]
                   , M.Swap 3                     -- [q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.Push memBeginning
                   , M.IAdd                       -- [memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.Dup 0, M.Dup 0             -- [memBeginning+q, memBeginning+q, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.MemLoad Nothing            -- [v_lo, memBeginning+q, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.Swap 1, M.Push 1, M.IAdd   -- [memBeginning+q+1, v_lo, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.MemLoad Nothing            -- [v_hi, v_lo, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.Dup 5, M.Dup 5             -- [mask_hi, mask_lo, v_hi, v_lo, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.IAnd64                     -- [v'_hi, v'_lo, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, i_lo, ...]
                   , M.Swap 7, M.Swap 1           -- [v'_lo, i_lo, memBeginning+q, 8*r, mask_hi, mask_lo, i_hi, v'_hi, ...]
                   , M.Swap 6                     -- [i_hi, i_lo, memBeginning+q, 8*r, mask_hi, mask_lo, v'_lo, v'_hi, ...]
                   , M.Dup 3, M.IShL64            -- [i'_hi, i'_lo, memBeginning+q, 8*r, mask_hi, mask_lo, v'_lo, v'_hi, ...]
                   , M.Swap 2, M.Swap 1           -- [i'_lo, memBeginning+q, i'_hi, 8*r, mask_hi, mask_lo, v'_lo, v'_hi, ...]
                   , M.Swap 3                     -- [8*r, memBeginning+q, i'_hi, i'_lo, mask_hi, mask_lo, v'_lo, v'_hi, ...]
                   , M.Swap 6, M.Swap 1           -- [memBeginning+q, v'_lo, i'_hi, i'_lo, mask_hi, mask_lo, 8*r, v'_hi, ...]
                   , M.Swap 7                     -- [v'_hi, v'_lo, i'_hi, i'_lo, mask_hi, mask_lo, 8*r, memBeginning+q, ...]
                   , M.IOr64                      -- [res_hi, res_lo, mask_hi, mask_lo, 8*r, memBeginning+q, ...]
                   , M.Dup 5                      -- [memBeginning+q, res_hi, res_lo, mask_hi, mask_lo, 8*r, memBeginning+q, ...]
                   , M.Push 1, M.IAdd             -- [memBeginning+q+1, res_hi, res_lo, mask_hi, mask_lo, 8*r, memBeginning+q, ...]
                   , M.MemStore Nothing, M.Drop   -- [res_lo, mask_hi, mask_lo, 8*r, memBeginning+q, ...]
                   , M.MoveUp 4                   -- [memBeginning+q, res_lo, mask_hi, mask_lo, 8*r, ...]
                   , M.MemStore Nothing, M.Drop   -- [mask_hi, mask_lo, 8*r, ...]
                   , M.Drop, M.Drop, M.Drop       -- [...]
                   ]
        -- TODO: ^^^^^^ use M.MoveUp more!


        -- turning an i32 into an i64 in wasm corresponds to pushing 0 on the stack.
        -- let's call the i32 'i'. before executing this, the stack looks like [i, ...],
        -- and after like: [0, i, ...].
        -- Since an i64 'x' on the stack is in Miden represented as [x_hi, x_lo], pushing 0
        -- effectively grabs the i32 for the low bits and sets the high 32 bits to 0.
        translateInstr _ W.I64ExtendUI32 = typed [W.I32] [W.I64] [M.Push 0]
        -- similarly, wrap drops the high 32 bits, which amounts to dropping the tip of the stack
        -- in miden, going from [v_hi, v_lo, ...] to [v_lo, ...]
        translateInstr _ W.I32WrapI64 = typed [W.I64] [W.I32] [M.Drop]
        -- this is a sign-aware extension, so we push 0 or maxBound :: Word32
        -- depending on whether the most significant bit of the i32 is 0 or 1.
        translateInstr _ W.I64ExtendSI32 = typed [W.I32] [W.I64]
            [ M.Dup 0                  -- [x, x, ...]
            , M.Push 2147483648        -- [2^31, x, x, ...]
            , M.IAnd                   -- [x & 2^31, x, ...]
            , M.Push 31, M.IShR        -- [x_highest_bit, x, ...]
            -- TODO: Use select
            , M.If
                [ M.Push 4294967295    -- [0b11..1, x, ...]
                ]
                [ M.Push 0             -- [0, x, ...]
                ]
            ]

        translateInstr _ W.I64Eqz = typed [W.I64] [W.I32] [M.IEqz64]

        translateInstr _ W.Drop = withPrefix
          -- is the top of the WASM stack an i32 or i64, at this point in time?
          -- i32 => 1 MASM 'drop', i64 => 2 MASM 'drop's.
          \case
            W.I32 -> return [M.Drop]
            W.I64 -> return [M.Drop, M.Drop]

        translateInstr _ W.Unreachable = pure [M.Push 0, M.Assert]

        translateInstr _ i = unsupportedInstruction i

translateIBinOp :: W.BitSize -> W.IBinOp -> V [M.Instruction]
-- TODO: the u64 module actually provides implementations of many binops for 64 bits
-- values.
translateIBinOp W.BS64 op = case op of
  W.IAdd  -> stackBinop W.I64 M.IAdd64
  W.ISub  -> stackBinop W.I64 M.ISub64
  W.IMul  -> stackBinop W.I64 M.IMul64
  W.IShl  -> stackBinop W.I64 M.IShL64
  W.IShrU -> stackBinop W.I64 M.IShR64
  W.IOr   -> stackBinop W.I64 M.IOr64
  W.IAnd  -> stackBinop W.I64 M.IAnd64
  W.IXor  -> stackBinop W.I64 M.IXor64
  _       -> unsupported64Bits op
translateIBinOp W.BS32 op = case op of
  W.IAdd  -> stackBinop W.I32 M.IAdd
  W.ISub  -> stackBinop W.I32 M.ISub
  W.IMul  -> stackBinop W.I32 M.IMul
  W.IShl  -> stackBinop W.I32 M.IShL
  W.IShrU -> stackBinop W.I32 M.IShR
  W.IAnd  -> stackBinop W.I32 M.IAnd
  W.IOr   -> stackBinop W.I32 M.IOr
  W.IXor  -> stackBinop W.I32 M.IXor
  W.IRemU -> stackBinop W.I32 M.IMod
  W.IDivU -> stackBinop W.I32 M.IDiv

  -- https://bisqwit.iki.fi/story/howto/bitmath/#DviIdivDiviSignedDivision
  W.IDivS ->
    typed [W.I32, W.I32] [W.I32]   -- [b, a, ...]
    ( [ M.Dup 1 ] ++ computeAbs ++ -- [abs(a), b, a, ...]
      [ M.Dup 1 ] ++ computeAbs ++ -- [abs(b), abs(a), b, a, ...]
      [ M.IDiv                     -- [abs(a)/abs(b), b, a, ...]
      , M.Swap 2                   -- [a, b, abs(a)/abs(b), ...]
      ] ++ computeIsNegative ++    -- [a_negative, b, abs(a)/abs(b), ...]
      [ M.Swap 1                   -- [b, a_negative, abs(a)/abs(b), ...]
      ] ++ computeIsNegative ++    -- [b_negative, a_negative, abs(a)/abs(b), ...]
      [ M.IXor                     -- [a_b_diff_sign, abs(a)/abs(b), ...]
      , M.If                       -- [abs(a)/abs(b), ...]
          computeNegate            -- [-abs(a)/abs(b), ...]
          []                       -- [abs(a)/abs(b), ...]
      ]
    )
  W.IShrS -> typed [W.I32, W.I32] [W.I32] -- [b, a, ...]
    ( [ M.Dup 1                  -- [a, b, a, ...]
      ] ++ computeIsNegative ++  -- [a_negative, b, a, ...]
      [ M.If                     -- [b, a, ...]
          [ M.Swap 1, M.INot     -- [~a, b, ...]
          , M.Swap 1             -- [b, ~a, ...]
          , M.IShR               -- [~a >> b, ...]
          , M.INot               -- [~(~a >> b), ...]
          ]
          [ M.IShR ]            -- [ a >> b, ...]
      ]
    )
  _       -> unsupportedInstruction (W.IBinOp W.BS32 op)

translateIRelOp :: W.BitSize -> W.IRelOp -> V [M.Instruction]
translateIRelOp W.BS64 op = case op of
  W.IEq  -> stackRelop W.I64 M.IEq64
  W.INe  -> stackRelop W.I64 M.INeq64
  W.ILtU -> stackRelop W.I64 M.ILt64
  W.IGtU -> stackRelop W.I64 M.IGt64
  W.ILeU -> stackRelop W.I64 M.ILte64
  W.IGeU -> stackRelop W.I64 M.IGte64
  _      -> unsupported64Bits op
translateIRelOp W.BS32 op = case op of
  W.IEq  -> stackRelop W.I32 (M.IEq Nothing)
  W.INe  -> stackRelop W.I32 M.INeq
  W.ILtU -> stackRelop W.I32 M.ILt
  W.IGtU -> stackRelop W.I32 M.IGt
  W.ILeU -> stackRelop W.I32 M.ILte
  W.IGeU -> stackRelop W.I32 M.IGte
  W.ILtS -> typed [W.I32, W.I32] [W.I32]        -- [b, a, ...]
    ( M.ISub                                    -- [a-b, ...]
      : computeIsNegative                       -- [a-b < 0, ...] =
                                                -- [a<b, ...]
    )
  W.IGtS -> typed [W.I32, W.I32] [W.I32]        -- [b, a, ...]
    ( [ M.Swap 1                                -- [b-a, ...]
      , M.ISub                                  -- [b-a, ...]
      ] ++ computeIsNegative                    -- [b-a < 0, ...] =
                                                -- [b<a, ...]
    )
  W.IGeS -> typed [W.I32, W.I32] [W.I32]              -- [b, a, ...]
      [ M.Dup 0, M.Dup 2                              -- [b, a, b, a, ...]
      , M.IEq Nothing                                 -- [a == b, b, a, ...]
      , M.If                                          -- [b, a, ...]
          [ M.Drop, M.Drop, M.Push 1 ]                -- [1, ...]
          ([ M.Swap 1, M.ISub ] ++ computeIsNegative) -- [a > b, ...]
      ]
  _      -> unsupportedInstruction (W.IRelOp W.BS32 op)

checkTypes :: [W.ValueType] -> V [W.ValueType]
checkTypes = traverse f
  where f W.I32 = pure W.I32
        f W.I64 = pure W.I64
        f t     = unsupportedArgType t

stackBinop :: W.ValueType -> M.Instruction -> V [M.Instruction]
stackBinop ty xs = typed [ty, ty] [ty] [xs]

stackRelop :: W.ValueType -> M.Instruction -> V [M.Instruction]
stackRelop ty xs = typed [ty, ty] [W.I32] [xs]

-- TODO: turn those into procedures?

computeAbs :: [M.Instruction]
computeAbs =           -- [x, ...]
  [ M.Dup 0 ] ++       -- [x, x, ...]
  computeIsNegative ++ -- [x_highest_bit, x, ...]
  [ M.If               -- [x, ...]
      computeNegate    -- [-x, ...]
      []               -- [x, ...]
  ]

-- negate a number using two's complement encoding:
-- 4294967295 = 2^32-1 is the largest Word32
-- 4294967295 + 1 wraps around to turn into 0
-- so 4294967295 - x + 1 "is indeed" -x, but computing
-- the subtraction first and then adding one is a very concise way
-- to negate a number using two's complement.
computeNegate :: [M.Instruction]
computeNegate =       -- [x, ...]
  [ M.Push 4294967295 -- [4294967295, x, ...]
  , M.Swap 1, M.ISub  -- [4294967295 - x, ...]
  , M.Push 1, M.IAdd  -- [4294967295 - x + 1, ...]
  ]

computeIsNegative :: [M.Instruction]
computeIsNegative = -- [x, ...]
  [ M.Push hi       -- [2^31, x, ...]
  , M.IGt           -- [x > 2^31, ...] (meaning it's a two's complement encoded negative integer)
  ]
  where hi = 2^(31::Int)

typed :: W.ParamsType -> W.ResultType -> a -> V a
typed params result x = maybe (bad $ ExpectedStack params) f . stripPrefix params =<< get
  where f stack = put (result <> stack) >> pure x

withPrefix :: (W.ValueType -> V a) -> V a
withPrefix f = get >>= \ case
  [] -> bad EmptyStack
  x:xs -> put xs >> f x

writeW32s :: [Word8] -> [M.Instruction]
writeW32s [] = []
writeW32s (a:b:c:d:xs) =
  let w = foldl' (.|.) 0 [ shiftL (fromIntegral x) (8 * i)
                          | (i, x) <- zip [0..] [a,b,c,d]
                          ]
  in [ M.Dup 0 -- [addr_u32, addr_u32, ...]
      , M.Push w -- [w, addr_u32, addr_u32, ...]
      , M.Swap 1 -- [addr_u32, w, addr_u32, ...]
      , M.MemStore Nothing -- [w, addr_u32, ...]
      , M.Drop -- [addr_u32, ...]
      , M.Push 1, M.IAdd -- [addr_u32+1, ...]
      ] ++ writeW32s xs
writeW32s xs = writeW32s $ xs ++ replicate (4-length xs) 0
