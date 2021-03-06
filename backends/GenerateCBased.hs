{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008, 2009  University of Kent

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program.  If not, see <http://www.gnu.org/licenses/>.
-}

-- | The function dictionary and various types and helper functions for backends based around C
module GenerateCBased where

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer hiding (tell)
import Data.Generics (Data)
import Data.HashTable (hashString)
import Data.Int (Int32)
import Data.List
import System.IO

import qualified AST as A
import CompState
import Errors
import Metadata
import Pass
import qualified Properties as Prop
import Utils

cCppCommonPreReq :: [Property]
cCppCommonPreReq =
 [Prop.afterRemoved
 ,Prop.arrayLiteralsExpanded
 ,Prop.assignFlattened
 ,Prop.assignParRemoved
 ,Prop.freeNamesToArgs
 ,Prop.functionCallsRemoved
 ,Prop.functionsRemoved
 ,Prop.inputCaseRemoved
 ,Prop.mainTagged
 ,Prop.nestedPulled
 ,Prop.outExpressionRemoved
 ,Prop.parsWrapped
 ,Prop.parUsageChecked
 ,Prop.subscriptsPulledUp
 ,Prop.typesResolvedInAST
 ,Prop.typesResolvedInState
 ]

type CGenOutput = Either [String] Handle
data CGenOutputs = CGenOutputs
  { cgenBody :: CGenOutput
  , cgenHeader :: CGenOutput
  }

--{{{  monad definition
type CGen' = StateT CGenOutputs PassM
type CGen = ReaderT GenOps CGen'

instance Die CGen where
  dieReport err = lift $ lift $ dieReport err
  
instance CSMR CGen where
  getCompState = lift getCompState

-- Do not nest calls to this function!
-- The function also puts in the #ifndef/#define/#endif stuff that prevents multiple
-- inclusion.
tellToHeader :: String -> CGen a -> CGen a
tellToHeader stem act
  = do st <- get
       put $ st { cgenBody = Left [] }
       x <- act
       st' <- get
       let Left mainBit = cgenBody st'
           nonce = "_" ++ stem ++ "_" ++ show (makePosInteger $ hashString $ concat mainBit)
           contents =
             "#ifndef " ++ nonce ++ "\n" ++
             "#define " ++ nonce ++ "\n" ++
             concat mainBit ++ "\n" ++
             "#endif\n"
       case cgenHeader st of
         Right h -> do liftIO $ hPutStr h contents
                       put $ st' { cgenBody = cgenBody st }
         Left ls -> do put $ st' { cgenBody = cgenBody st
                                 , cgenHeader = Left $ ls ++ [contents]
                                 }
       return x
  where
    makePosInteger :: Int32 -> Integer
    makePosInteger n = toInteger n + (toInteger (maxBound :: Int32))

tell :: [String] -> CGen ()
tell x = do st <- get
            case cgenBody st of
              Left prev -> put $ st { cgenBody = Left (prev ++ x) }
              Right h -> liftIO $ mapM_ (hPutStr h) x

csmLift :: PassM a -> CGen a
csmLift = lift . lift
--}}}

-- | A function that applies a subscript to a variable.
type SubscripterFunction = A.Variable -> A.Variable

data Level = TopLevel | NotTopLevel

--{{{  generator ops
-- | Operations for turning various things into C.
-- These are in a structure so that we can reuse operations in other
-- backends without breaking the mutual recursion.
data GenOps = GenOps {
    -- | Generates code when a variable goes out of scope (e.g. deallocating memory).
    declareFree :: Meta -> A.Type -> A.Variable -> Maybe (CGen ()),
    -- | Generates code when a variable comes into scope (e.g. allocating memory, initialising variables).
    declareInit :: Meta -> A.Type -> A.Variable -> Maybe (CGen ()),
    -- | Generates an individual parameter to a function\/proc.
    genActual :: CGen () -> A.Formal -> A.Actual -> CGen (),
    -- | Generates the list of actual parameters to a function\/proc.
    genActuals :: CGen () -> [A.Formal] -> [A.Actual] -> CGen (),
    genAllocMobile :: Meta -> A.Type -> Maybe A.Expression -> CGen(),
    genAlt :: Bool -> A.Structured A.Alternative -> CGen (),
    -- | Generates the given array element expressions as a flattened (one-dimensional) list of literals
    genArrayLiteralElems :: A.Structured A.Expression -> CGen (),
    -- | Writes out the actual data storage array name.
    genArrayStoreName :: A.Name -> CGen(),
    -- | Generates an array subscript for the given variable (with error checking according to the first variable), using the given expression list as subscripts
    genArraySubscript :: A.SubscriptCheck -> A.Variable -> [(Meta, CGen ())] -> CGen (),
    genAssert :: Meta -> A.Expression -> CGen (),
    -- | Generates an assignment statement with a single destination and single source.
    genAssign :: Meta -> [A.Variable] -> A.ExpressionList -> CGen (),
    -- | Generates the number of bytes in a fixed size type, fails if a free dimension is present and is not allowed.
    -- The Either parameter is either an array variable (to use the _sizes array of) or a boolean specifying
    -- wheter or not one free dimension is allowed (True <=> allowed).
    genBytesIn :: Meta -> A.Type -> Either Bool A.Variable -> CGen (),
    -- | Generates a case statement over the given expression with the structured as the body.
    genCase :: Meta -> A.Expression -> A.Structured A.Option -> CGen (),
    genCheckedConversion :: Meta -> A.Type -> A.Type -> CGen () -> CGen (),
    genClearMobile :: Meta -> A.Variable -> CGen (),
    genCloneMobile :: Meta -> A.Expression -> CGen (),
    genConversion :: Meta -> A.ConversionMode -> A.Type -> A.Expression -> CGen (),
    genConversionSymbol :: A.Type -> A.Type -> A.ConversionMode -> CGen (),
    getCType :: Meta -> A.Type -> A.AbbrevMode -> CGen CType,
    genDecl :: Level -> A.AbbrevMode -> A.Type -> A.Name -> CGen (),
    -- | Generates a declaration of a variable of the specified type and name.  
    -- The Bool indicates whether the declaration is inside a record (True) or not (False).
    genDeclaration :: Level -> A.Type -> A.Name -> Bool -> CGen (),
    genDirectedVariable :: Meta -> A.Type -> CGen () -> A.Direction -> CGen (),
    genExpression :: A.Expression -> CGen (),
    genFlatArraySize :: [A.Dimension] -> CGen (),
    -- Bool is true if this is for the header:
    genForwardDeclaration :: Bool -> A.Specification -> CGen(),
    -- | Only used for built-in operators at the moment:
    genFunctionCall :: Meta -> A.Name -> [A.Expression] -> CGen (),
    -- | Gets the current time into the given variable
    genGetTime :: A.Variable -> CGen (),
    -- | Generates an IF statement (which can have replicators, specifications and such things inside it).
    genIf :: Meta -> A.Structured A.Choice -> CGen (),
    genInput :: A.Variable -> A.InputMode -> CGen (),
    genInputItem :: A.Variable -> A.InputItem -> Maybe A.Process -> CGen (),
    genIntrinsicFunction :: Meta -> String -> [A.Expression] -> CGen (),
    genIntrinsicProc :: Meta -> String -> [A.Actual] -> CGen (),
    genListAssign :: A.Variable -> A.Expression -> CGen (),
    genListConcat :: A.Expression -> A.Expression -> CGen (),
    genListLiteral :: A.Structured A.Expression -> A.Type -> CGen (),
    genListSize :: A.Variable -> CGen (),
    genLiteral :: A.LiteralRepr -> A.Type -> CGen (),
    genLiteralRepr :: A.LiteralRepr -> A.Type -> CGen (),
    genMissing :: String -> CGen (),
    genMissingC :: CGen String -> CGen (),
    -- | Generates an output statement.
    genOutput :: A.Variable -> [(A.Type, A.OutputItem)] -> CGen (),
    -- | Generates an output statement for a tagged protocol.
    genOutputCase :: A.Variable -> A.Name -> [A.OutputItem] -> CGen (),
    -- | Generates an output for an individual item.
    genOutputItem :: A.Type -> A.Variable -> A.OutputItem -> CGen (),
    -- | Generates a loop that maps over every element in a (potentially multi-dimensional) array
    genOverArray :: Meta -> A.Variable -> (SubscripterFunction -> Maybe (CGen ())) -> CGen (),
    genPar :: A.ParMode -> A.Structured A.Process -> CGen (),
    genPoison :: Meta -> A.Variable -> CGen (),
    genProcCall :: A.Name -> [A.Actual] -> CGen (),
    genProcess :: A.Process -> CGen (),
    genRecordTypeSpec :: Bool -> A.Name -> A.RecordAttr -> [(A.Name, A.Type)] -> CGen (),
    genReplicatorStart :: A.Name -> A.Replicator -> CGen (),
    genReplicatorEnd :: A.Replicator -> CGen (),
    -- | Generates the three bits of a for loop (e.g. @int i = 0; i < 10; i++@ for the given replicator)
    genReplicatorLoop :: A.Name -> A.Replicator -> CGen (),
    genReschedule :: CGen(),
    genRetypeSizes :: Meta -> A.Type -> A.Name -> A.Type -> A.Variable -> CGen (),
    genSetAff :: Meta -> A.Expression -> CGen (),
    genSetPri :: Meta -> A.Expression -> CGen (),
    genSeq :: A.Structured A.Process -> CGen (),
    genSpec :: forall b. Level -> A.Specification -> CGen b -> CGen b,
    genSpecMode :: A.SpecMode -> CGen (),
    -- | Generates a STOP process that uses the given Meta tag and message as its printed message.
    genStop :: Meta -> String -> CGen (),
    genStructured :: forall a b. Data a => Level -> A.Structured a -> (Meta -> a -> CGen b) -> CGen [b],
    genTimerRead :: A.Variable -> A.Variable -> CGen (),
    genTimerWait :: A.Expression -> CGen (),
    genTopLevel :: String -> A.AST -> CGen (),
    genTypeSymbol :: String -> A.Type -> CGen (),
    genUnfoldedExpression :: A.Expression -> CGen (),
    genUnfoldedVariable :: Meta -> A.Variable -> CGen (),
    -- Like genVariable, but modifies the desired CType
    genVariable' :: A.Variable -> A.AbbrevMode -> (CType -> CType) -> CGen (),
    -- | Generates a variable, with no indexing checks anywhere
    genVariableUnchecked :: A.Variable -> A.AbbrevMode -> CGen (),
    -- | Generates a while loop with the given condition and body.
    genWhile :: A.Expression -> A.Process -> CGen (),
    getScalarType :: A.Type -> Maybe String,
    introduceSpec :: Level -> A.Specification -> CGen (),
    removeSpec :: A.Specification -> CGen ()
  }

-- | Generates a variable, with indexing checks if needed
genVariable :: GenOps -> A.Variable -> A.AbbrevMode -> CGen ()
genVariable ops v am = genVariable' ops v am id

-- | Call an operation in GenOps.
class CGenCall a where
  call :: (GenOps -> a) -> a

instance CGenCall (CGen z) where
  call f = do ops <- ask
              f ops

instance CGenCall (a -> CGen z) where
--  call :: (a -> CGen b) -> a -> CGen b
  call f x0 = do ops <- ask
                 f ops x0

instance CGenCall (a -> b -> CGen z) where
  call f x0 x1
    = do ops <- ask
         f ops x0 x1

instance CGenCall (a -> b -> c -> CGen z) where
  call f x0 x1 x2
    = do ops <- ask
         f ops x0 x1 x2

instance CGenCall (a -> b -> c -> d -> CGen z) where
  call f x0 x1 x2 x3
    = do ops <- ask
         f ops x0 x1 x2 x3

instance CGenCall (a -> b -> c -> d -> e -> CGen z) where
  call f x0 x1 x2 x3 x4
    = do ops <- ask
         f ops x0 x1 x2 x3 x4

fget :: (GenOps -> a) -> CGen a
fget = asks

-- Handles are body, header, occam-inc
generate :: GenOps -> (Handle, Handle) -> String -> A.AST -> PassM ()
generate ops (hb, hh) hname ast
  = evalStateT (runReaderT (call genTopLevel hname ast) ops)
      (CGenOutputs (Right hb) (Right hh))

genComma :: CGen ()
genComma = tell [","]

seqComma :: [CGen ()] -> CGen ()
seqComma ps = sequence_ $ intersperse genComma ps

-- C or C++ type, really.
data CType
  = Plain String
    | Pointer CType
    | Const CType
    | Template String [Either CType A.Expression]
--    | Subscript CType
    deriving (Eq)

instance Show CType where
  show (Plain s) = s
  show (Pointer t) = show t ++ "*"
  show (Const t) = show t ++ " const"
  show (Template wr cts) = wr ++ "<" ++ concat (intersperse "," $ map (either show show) cts) ++ ">/**/"
--  show (Subscript t) = "(" ++ show t ++ "[n])"

replacePlainType :: String -> String -> CType -> CType
replacePlainType old new (Const ct) = Const $ replacePlainType old new ct
replacePlainType old new (Pointer ct) = Pointer $ replacePlainType old new ct
replacePlainType old new (Template t xs)
  = Template t $ [transformEither (replacePlainType old new) id x | x <- xs]
replacePlainType old new (Plain t)
  | old == t  = Plain new
  | otherwise = Plain t

stripPointers :: CType -> CType
stripPointers (Pointer t) = t
stripPointers (Const (Pointer t)) = t
stripPointers t = t

-- Like Eq, but ignores const
closeEnough :: CType -> CType -> Bool
closeEnough (Const t) t' = closeEnough t t'
closeEnough t (Const t') = closeEnough t t'
closeEnough (Pointer t) (Pointer t') = closeEnough t t'
closeEnough (Plain s) (Plain s') = s == s'
closeEnough (Template wr cts) (Template wr' cts')
  = wr == wr' && length cts == length cts' && and (zipWith closeEnough' cts cts')
  where
    closeEnough' (Left ct) (Left ct') = closeEnough ct ct'
    closeEnough' (Right _) (Right _) = True -- can't really check
    closeEnough' _ _ = False
closeEnough _ _ = False

-- Given some code to generate, and its type, and the type that you actually want,
-- adds the required decorators.  Only pass it simplified types!
dressUp :: (Meta, String) -> (CGen (), CType) -> CType -> CGen ()
dressUp _ (gen, t) t' | t `closeEnough` t' = gen
--Every line after here is not close enough, so we know equality fails:
dressUp m (gen, Pointer t) (Pointer t')
  = dressUp m (gen, t) t'
dressUp m (gen, Const t) t'
  = dressUp m (gen, t) t'
dressUp m (gen, t) (Const t')
  = dressUp m (gen, t) t'
dressUp m (gen, t) (Pointer t')
  = dressUp m (tell ["&"] >> gen, t) t'
dressUp m (gen, Pointer t) t'
  = dressUp m (tell ["*"] >> gen, t) t'
dressUp (m, s) (gen, t) t'
  = dieP m $ "Types cannot be brought together (" ++ s ++ "): " ++ show t ++ " and " ++ show t'

genType :: A.Type -> CGen ()
genType t = do ct <- call getCType emptyMeta t A.Original
               tell [show ct]

genCType :: Meta -> A.Type -> A.AbbrevMode -> CGen ()
genCType m t am = do ct <- call getCType m t am
                     tell [show ct]
