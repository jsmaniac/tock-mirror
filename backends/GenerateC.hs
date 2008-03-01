{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008  University of Kent

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

-- | Generate C code from the mangled AST.
module GenerateC (cgenLiteralRepr, cgenOps, cintroduceSpec, cPreReq, fget, genComma, genCPasses, generate, generateC, genLeftB, genMeta, genName, genRightB, GenOps(..), indexOfFreeDimensions, seqComma, withIf ) where

import Data.Char
import Data.Generics
import Data.List
import Data.Maybe
import qualified Data.Set as Set
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Text.Printf
import Text.Regex

import qualified AST as A
import BackendPasses
import CompState
import Errors
import EvalConstants
import EvalLiterals
import GenerateCBased
import Metadata
import Pass
import qualified Properties as Prop
import ShowCode
import TLP
import Types
import Utils

--{{{  passes related to C generation
genCPasses :: [Pass]
genCPasses = makePassesDep' ((== BackendC) . csBackend)
  [ ("Identify parallel processes", identifyParProcs, [Prop.parsWrapped], [])
   ,("Transform wait for guards into wait until guards", transformWaitFor, [], [Prop.waitForRemoved])
  ]
--}}}

cPreReq :: [Property]
cPreReq = cCppCommonPreReq ++ [Prop.parsIdentified, Prop.waitForRemoved]

-- | Operations for the C backend.
cgenOps :: GenOps
cgenOps = GenOps {
    declareArraySizes = cdeclareArraySizes,
    declareFree = cdeclareFree,
    declareInit = cdeclareInit,
    genActual = cgenActual,
    genActuals = cgenActuals,
    genAlt = cgenAlt,
    genAllocMobile = cgenAllocMobile,
    genArrayLiteralElems = cgenArrayLiteralElems,
    genArraySize = cgenArraySize,
    genArraySizesLiteral = cgenArraySizesLiteral,
    genArrayStoreName = genName,
    genArraySubscript = cgenArraySubscript,
    genAssert = cgenAssert,
    genAssign = cgenAssign,
    genBytesIn = cgenBytesIn,
    genCase = cgenCase,
    genCheckedConversion = cgenCheckedConversion,
    genClearMobile = cgenClearMobile,
    genConversion = cgenConversion,
    genConversionSymbol = cgenConversionSymbol,
    genDecl = cgenDecl,
    genDeclType = cgenDeclType,
    genDeclaration = cgenDeclaration,
    genDirectedVariable = cgenDirectedVariable,
    genDyadic = cgenDyadic,
    genExpression = cgenExpression,
    genFlatArraySize = cgenFlatArraySize,
    genFormal = cgenFormal,
    genFormals = cgenFormals,
    genForwardDeclaration = cgenForwardDeclaration,
    genFuncDyadic = cgenFuncDyadic,
    genFuncMonadic = cgenFuncMonadic,
    genGetTime = cgenGetTime,
    genIf = cgenIf,
    genInput = cgenInput,
    genInputItem = cgenInputItem,
    genIntrinsicFunction = cgenIntrinsicFunction,
    genIntrinsicProc = cgenIntrinsicProc,
    genLiteral = cgenLiteral,
    genLiteralRepr = cgenLiteralRepr,
    genMissing = cgenMissing,
    genMissingC = (\x -> x >>= cgenMissing),
    genMonadic = cgenMonadic,
    genOutput = cgenOutput,
    genOutputCase = cgenOutputCase,
    genOutputItem = cgenOutputItem,
    genOverArray = cgenOverArray,
    genPar = cgenPar,
    genProcCall = cgenProcCall,
    genProcess = cgenProcess,
    genRecordTypeSpec = cgenRecordTypeSpec,
    genReplicator = cgenReplicator,
    genReplicatorLoop = cgenReplicatorLoop,
    genRetypeSizes = cgenRetypeSizes,
    genSeq = cgenSeq,
    genSimpleDyadic = cgenSimpleDyadic,
    genSimpleMonadic = cgenSimpleMonadic,
    genSizeSuffix = cgenSizeSuffix,
    genSlice = cgenSlice,
    genSpec = cgenSpec,
    genSpecMode = cgenSpecMode,
    genStop = cgenStop,
    genStructured = cgenStructured,
    genTLPChannel = cgenTLPChannel,
    genTimerRead = cgenTimerRead,
    genTimerWait = cgenTimerWait,
    genTopLevel = cgenTopLevel,
    genType = cgenType,
    genTypeSymbol = cgenTypeSymbol,
    genUnfoldedExpression = cgenUnfoldedExpression,
    genUnfoldedVariable = cgenUnfoldedVariable,
    genVariable = cgenVariable,
    genVariableAM = cgenVariableAM,
    genVariableUnchecked = cgenVariableUnchecked,
    genWhile = cgenWhile,
    genWait = cgenWait,
    getScalarType = cgetScalarType,
    introduceSpec = cintroduceSpec,
    removeSpec = cremoveSpec
  }
--}}}

--{{{  top-level
generate :: GenOps -> A.AST -> PassM String
generate ops ast = execWriterT (runReaderT (call genTopLevel ast) ops) >>* concat

generateC :: A.AST -> PassM String
generateC = generate cgenOps

cgenTLPChannel :: TLPChannel -> CGen ()
cgenTLPChannel TLPIn = tell ["in"]
cgenTLPChannel TLPOut = tell ["out"]
cgenTLPChannel TLPError = tell ["err"]

cgenTopLevel :: A.AST -> CGen ()
cgenTopLevel s
    =  do tell ["#include <tock_support_cif.h>\n"]
          cs <- get
          (tlpName, chans) <- tlpInterface

          tell ["extern int " ++ nameString n ++ "_stack_size;\n"
                | n <- tlpName : (Set.toList $ csParProcs cs)]

          sequence_ $ map (call genForwardDeclaration) (listify (const True :: A.Specification -> Bool) s)
          call genStructured s (\m _ -> tell ["\n#error Invalid top-level item: ", show m])

          tell ["void tock_main (Workspace wptr) {\n\
                \    Workspace tlp = ProcAlloc (wptr, ", show $ length chans, ", "]
          genName tlpName
          tell ["_stack_size);\n"]
          sequence_ [do tell ["    ProcParam (wptr, tlp, " ++ show i ++ ", "]
                        call genTLPChannel c
                        tell [");\n"]
                     | (i, (_, c)) <- zip [(0 :: Int)..] chans]

          tell ["\n\
                \    LightProcBarrier bar;\n\
                \    LightProcBarrierInit (wptr, &bar, 1);\n\
                \    LightProcStart (wptr, &bar, tlp, (Process) "]
          genName tlpName
          tell [");\n\
                \    LightProcBarrierWait (wptr, &bar);\n\
                \    Shutdown (wptr);\n\
                \}\n\
                \\n\
                \int main (int argc, char *argv[]) {\n\
                \    if (!ccsp_init ())\n\
                \        return 1;\n\
                \\n\
                \    Workspace p = ProcAllocInitial (0, 512);\n\
                \    ProcStartInitial (p, tock_main);\n\
                \\n\
                \    // NOTREACHED\n\
                \    return 0;\n\
                \}\n"]
--}}}

--{{{  utilities
cgenMissing :: String -> CGen ()
cgenMissing s = tell ["\n#error Unimplemented: ", s, "\n"]

--{{{  simple punctuation
genComma :: CGen ()
genComma = tell [","]

seqComma :: [CGen ()] -> CGen ()
seqComma ps = sequence_ $ intersperse genComma ps

genLeftB :: CGen ()
genLeftB = tell ["{"]

genRightB :: CGen ()
genRightB = tell ["}"]
--}}}

-- | Map an operation over every item of an occam array.
cgenOverArray :: Meta -> A.Variable -> (SubscripterFunction -> Maybe (CGen ())) -> CGen ()
cgenOverArray m var func
    =  do A.Array ds _ <- typeOfVariable var
          specs <- sequence [makeNonceVariable "i" m A.Int A.VariableName A.Original | _ <- ds]
          let indices = [A.Variable m n | A.Specification _ n _ <- specs]

          let arg = (\var -> foldl (\v s -> A.SubscriptedVariable m s v) var [A.Subscript m $ A.ExprVariable m i | i <- indices])
          case func arg of
            Just p ->
              do sequence_ [do tell ["for(int "]
                               call genVariable i
                               tell ["=0;"]
                               call genVariable i
                               tell ["<"]
                               call genVariable var
                               call genSizeSuffix (show v)
                               tell [";"]
                               call genVariable i
                               tell ["++){"]
                            | (v :: Integer, i) <- zip [0..] indices]
                 p
                 sequence_ [tell ["}"] | _ <- indices]
            Nothing -> return ()

-- | Generate code for one of the Structured types.
cgenStructured :: Data a => A.Structured a -> (Meta -> a -> CGen ()) -> CGen ()
cgenStructured (A.Rep _ rep s) def = call genReplicator rep (call genStructured s def)
cgenStructured (A.Spec _ spec s) def = call genSpec spec (call genStructured s def)
cgenStructured (A.ProcThen _ p s) def = call genProcess p >> call genStructured s def
cgenStructured (A.Several _ ss) def = sequence_ [call genStructured s def | s <- ss]
cgenStructured (A.Only m s) def = def m s

--}}}

--{{{  metadata
-- | Turn a Meta into a string literal that can be passed to a function
-- expecting a const char * argument.
genMeta :: Meta -> CGen ()
genMeta m = tell ["\"", show m, "\""]
--}}}

--{{{  names
nameString :: A.Name -> String
nameString n = [if c == '.' then '_' else c | c <- A.nameName n]

genName :: A.Name -> CGen ()
genName n = tell [nameString n]
--}}}

--{{{  types
-- | If a type maps to a simple C type, return Just that; else return Nothing.
cgetScalarType :: A.Type -> Maybe String
cgetScalarType A.Bool = Just "bool"
cgetScalarType A.Byte = Just "uint8_t"
cgetScalarType A.UInt16 = Just "uint16_t"
cgetScalarType A.UInt32 = Just "uint32_t"
cgetScalarType A.UInt64 = Just "uint64_t"
cgetScalarType A.Int8 = Just "int8_t"
cgetScalarType A.Int = Just "int"
cgetScalarType A.Int16 = Just "int16_t"
cgetScalarType A.Int32 = Just "int32_t"
cgetScalarType A.Int64 = Just "int64_t"
cgetScalarType A.Real32 = Just "float"
cgetScalarType A.Real64 = Just "double"
cgetScalarType A.Timer = Just "Time"
cgetScalarType A.Time = Just "Time"
cgetScalarType _ = Nothing

-- | Generate the C type corresponding to a variable being declared.
-- It must be possible to use this in arrays.
cgenType :: A.Type -> CGen ()
cgenType (A.Array _ t)
    =  do call genType t
          case t of
            A.Chan A.DirUnknown _ _ -> tell ["*"]
            _ -> return ()
          tell ["*"]
cgenType (A.Record n) = genName n
cgenType (A.Mobile t@(A.Array {})) = call genType t
cgenType (A.Mobile t) = call genType t >> tell ["*"]

-- UserProtocol -- not used
-- Channels are of type "Channel", but channel-ends are of type "Channel*"
cgenType (A.Chan A.DirUnknown _ t) = tell ["Channel"]
cgenType (A.Chan _ _ t) = tell ["Channel*"]
-- Counted -- not used
-- Any -- not used
--cgenType (A.Port t) =

--TODO have a pass that declares these list types:
cgenType t@(A.List {}) = tell [subRegex (mkRegex "[^A-Za-z0-9]") (show t) ""]

cgenType t
 = do f <- fget getScalarType
      case f t of
        Just s -> tell [s]
        Nothing -> call genMissingC $ formatCode "genType %" t

indexOfFreeDimensions :: [A.Dimension] -> [Int]
indexOfFreeDimensions = (mapMaybe indexOfFreeDimensions') . (zip [0..])
  where
    indexOfFreeDimensions' :: (Int,A.Dimension) -> Maybe Int
    indexOfFreeDimensions' (_, A.Dimension _) = Nothing
    indexOfFreeDimensions' (n, A.UnknownDimension) = Just n


-- | Generate the number of bytes in a type.
cgenBytesIn :: Meta -> A.Type -> Either Bool A.Variable -> CGen ()
cgenBytesIn m t v
    = do  case (t, v) of
            (A.Array ds _, Left freeDimensionAllowed) ->
              case (length (indexOfFreeDimensions ds), freeDimensionAllowed) of
                (0,_) -> return ()
                (1,False) -> dieP m "genBytesIn type with unknown dimension, when unknown dimensions are not allowed"
                (1,True) -> return ()
                (_,_) -> dieP m "genBytesIn type with more than one free dimension"
            _ -> return ()
          genBytesIn' t
  where
    genBytesIn' :: A.Type -> CGen ()
    genBytesIn' (A.Array ds t)
      = do mapM_ genBytesInArrayDim (reverse $ zip ds [0..]) --The reverse is simply to match the existing tests
           genBytesIn' t

    genBytesIn' (A.Record n)
      = do tell ["sizeof("]
           genName n
           tell [")"]
    -- This is so that we can do RETYPES checks on channels; we don't actually
    -- allow retyping between channels and other things.
    genBytesIn' t@(A.Chan {})
      = do tell ["sizeof("]
           call genType t
           tell [")"]
    genBytesIn' t
      = do f <- fget getScalarType
           case f t of
             Just s -> tell ["sizeof(", s, ")"]
             Nothing -> diePC m $ formatCode "genBytesIn' %" t

    genBytesInArrayDim :: (A.Dimension,Int) -> CGen ()
    genBytesInArrayDim (A.Dimension n, _) = tell [show n, "*"]
    genBytesInArrayDim (A.UnknownDimension, i)
        = case v of
            Right rv ->
              do call genVariable rv
                 call genSizeSuffix (show i)
                 tell ["*"]
            _ -> return ()

--}}}

--{{{  declarations
cgenDeclType :: A.AbbrevMode -> A.Type -> CGen ()
cgenDeclType am t
    =  do when (am == A.ValAbbrev) $ tell ["const "]
          call genType t
          case t of
            A.Array _ _ -> return ()
            A.Chan A.DirInput _ _ -> return ()
            A.Chan A.DirOutput _ _ -> return ()
            A.Record _ -> tell ["*const"]
            _ -> when (am == A.Abbrev) $ tell ["*const"]

cgenDecl :: A.AbbrevMode -> A.Type -> A.Name -> CGen ()
cgenDecl am t n
    =  do call genDeclType am t
          tell [" "]
          genName n
--}}}

--{{{  conversions
cgenCheckedConversion :: Meta -> A.Type -> A.Type -> CGen () -> CGen ()
cgenCheckedConversion m fromT toT exp
    =  do tell ["(("]
          call genType toT
          tell [") "]
          if isSafeConversion fromT toT
            then exp
            else do call genTypeSymbol "range_check" fromT
                    tell [" ("]
                    call genTypeSymbol "mostneg" toT
                    tell [", "]
                    call genTypeSymbol "mostpos" toT
                    tell [", "]
                    exp
                    tell [", "]
                    genMeta m
                    tell [")"]
          tell [")"]

cgenConversion :: Meta -> A.ConversionMode -> A.Type -> A.Expression -> CGen ()
cgenConversion m A.DefaultConversion toT e
    =  do fromT <- typeOfExpression e
          call genCheckedConversion m fromT toT (call genExpression e)
cgenConversion m cm toT e
    =  do fromT <- typeOfExpression e
          case (isSafeConversion fromT toT, isRealType fromT, isRealType toT) of
            (True, _, _) ->
              -- A safe conversion -- no need for a check.
              call genCheckedConversion m fromT toT (call genExpression e)
            (_, True, True) ->
              -- Real to real.
              do call genConversionSymbol fromT toT cm
                 tell [" ("]
                 call genExpression e
                 tell [", "]
                 genMeta m
                 tell [")"]
            (_, True, False) ->
              -- Real to integer -- do real -> int64_t -> int.
              do let exp = do call genConversionSymbol fromT A.Int64 cm
                              tell [" ("]
                              call genExpression e
                              tell [", "]
                              genMeta m
                              tell [")"]
                 call genCheckedConversion m A.Int64 toT exp
            (_, False, True) ->
              -- Integer to real -- do int -> int64_t -> real.
              do call genConversionSymbol A.Int64 toT cm
                 tell [" ("]
                 call genCheckedConversion m fromT A.Int64 (call genExpression e)
                 tell [", "]
                 genMeta m
                 tell [")"]
            _ -> call genMissing $ "genConversion " ++ show cm

cgenConversionSymbol :: A.Type -> A.Type -> A.ConversionMode -> CGen ()
cgenConversionSymbol fromT toT cm
    =  do tell ["occam_convert_"]
          call genType fromT
          tell ["_"]
          call genType toT
          tell ["_"]
          case cm of
            A.Round -> tell ["round"]
            A.Trunc -> tell ["trunc"]
--}}}

--{{{  literals
cgenLiteral :: A.LiteralRepr -> A.Type -> CGen ()
cgenLiteral lr t
    = if isStringLiteral lr
        then do tell ["\""]
                let A.ArrayLiteral _ aes = lr
                sequence_ [genByteLiteral s
                           | A.ArrayElemExpr (A.Literal _ _ (A.ByteLiteral _ s)) <- aes]
                tell ["\""]
        else call genLiteralRepr lr t

-- | Does a LiteralRepr represent something that can be a plain string literal?
isStringLiteral :: A.LiteralRepr -> Bool
isStringLiteral (A.ArrayLiteral _ aes)
    = and [case ae of
             A.ArrayElemExpr (A.Literal _ _ (A.ByteLiteral _ _)) -> True
             _ -> False
           | ae <- aes]
isStringLiteral _ = False

genLitSuffix :: A.Type -> CGen ()
genLitSuffix A.UInt32 = tell ["U"]
genLitSuffix A.Int64 = tell ["LL"]
genLitSuffix A.UInt64 = tell ["ULL"]
genLitSuffix A.Real32 = tell ["F"]
genLitSuffix _ = return ()

cgenLiteralRepr :: A.LiteralRepr -> A.Type -> CGen ()
cgenLiteralRepr (A.RealLiteral m s) t = tell [s] >> genLitSuffix t
cgenLiteralRepr (A.IntLiteral m s) t
  = do genDecimal s
       genLitSuffix t
cgenLiteralRepr (A.HexLiteral m s) t
  = do f <- fget getScalarType
       ct <- case f t of
         Just ct -> return ct
         Nothing -> diePC m $ formatCode "Non-scalar type for hex literal: " t
       tell ["((",ct,")0x", s]
       genLitSuffix t
       tell [")"]
cgenLiteralRepr (A.ByteLiteral m s) _ = tell ["'"] >> genByteLiteral s >> tell ["'"]
cgenLiteralRepr (A.ArrayLiteral m aes) _
    =  do genLeftB
          call genArrayLiteralElems aes
          genRightB
cgenLiteralRepr (A.RecordLiteral _ es) _
    =  do genLeftB
          seqComma $ map (call genUnfoldedExpression) es
          genRightB

-- | Generate an expression inside a record literal.
--
-- This is awkward: the sort of literal that this produces when there's a
-- variable in here cannot always be compiled at the top level of a C99 program
-- -- because in C99, an array subscript is not a constant, even if it's a
-- constant subscript of a constant array.  So we need to be sure that when we
-- use this at the top level, the thing we're unfolding only contains literals.
-- Yuck!
cgenUnfoldedExpression :: A.Expression -> CGen ()
cgenUnfoldedExpression (A.Literal _ t lr)
    =  do call genLiteralRepr lr t
          case t of
            A.Array ds _ ->
              do genComma
                 call genArraySizesLiteral undefined t --TODO work this out for C++
            _ -> return ()
cgenUnfoldedExpression (A.ExprVariable m var) = call genUnfoldedVariable m var
cgenUnfoldedExpression e = call genExpression e

-- | Generate a variable inside a record literal.
cgenUnfoldedVariable :: Meta -> A.Variable -> CGen ()
cgenUnfoldedVariable m var
    =  do t <- typeOfVariable var
          case t of
            A.Array ds _ ->
              do genLeftB
                 unfoldArray ds var
                 genRightB
                 genComma
                 call genArraySizesLiteral undefined t --TODO work this out for C++
            A.Record _ ->
              do genLeftB
                 fs <- recordFields m t
                 seqComma [call genUnfoldedVariable m (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
                 genRightB
            -- We can defeat the usage check here because we know it's safe; *we're*
            -- generating the subscripts.
            -- FIXME Is that actually true for something like [a[x]]?
            _ -> call genVariableUnchecked var
  where
    unfoldArray :: [A.Dimension] -> A.Variable -> CGen ()
    unfoldArray [] v = call genUnfoldedVariable m v
    unfoldArray (A.Dimension n:ds) v
      = seqComma $ [unfoldArray ds (A.SubscriptedVariable m (A.Subscript m $ makeConstant m i) v)
                    | i <- [0..(n - 1)]]
    unfoldArray _ _ = dieP m "trying to unfold array with unknown dimension"

-- | Generate a decimal literal -- removing leading zeroes to avoid producing
-- an octal literal!
genDecimal :: String -> CGen ()
genDecimal "0" = tell ["0"]
genDecimal ('0':s) = genDecimal s
genDecimal ('-':s) = tell ["-"] >> genDecimal s
genDecimal s = tell [s]

cgenArrayLiteralElems :: [A.ArrayElem] -> CGen ()
cgenArrayLiteralElems aes
    = seqComma $ map genElem aes
  where
    genElem :: A.ArrayElem -> CGen ()
    genElem (A.ArrayElemArray aes) = call genArrayLiteralElems aes
    genElem (A.ArrayElemExpr e) = call genUnfoldedExpression e

genByteLiteral :: String -> CGen ()
genByteLiteral s
    =  do c <- evalByte s
          tell [convByte c]

convByte :: Char -> String
convByte '\'' = "\\'"
convByte '"' = "\\\""
convByte '\\' = "\\\\"
convByte '\r' = "\\r"
convByte '\n' = "\\n"
convByte '\t' = "\\t"
convByte c
  | o == 0              = "\\0"
  | (o < 32 || o > 127) = printf "\\%03o" o
  | otherwise           = [c]
  where o = ord c
--}}}

--{{{  variables
{-
The various types are generated like this:

                        ================= Use =================
                        Original        ValAbbrev   Abbrev
                        --------------------------------------
INT x:                  int x;          int x;      int *x;
  x                     x               x           *x

[10]INT xs:             int xs[10];     int *xs;    int *xs;
  xs                    xs              xs          xs
  xs[i]                 xs[i]           xs[i]       xs[i]

[20][10]INT xss:        int xss[20*10]; int *xss;   int *xss;
  xss                   xss             xss         xss
  xss[i]                &xss[i*10]      &xss[i*10]  &xss[i*10]  (where 10 = xss_sizes[1])
  xss[i][j]             xss[i*10+j]     xss[i*10+j] xss[i*10+j]

[6][4][2]INT xsss:      int xsss[6*4*2]; int *xsss;
  xsss                  xsss             (as left)
  xsss[i]               &xsss[i*4*2]
  xsss[i][j]            &xsss[i*4*2+j*2]
  xsss[i][j][k]         xsss[i*4*2+j*2+k]

MYREC r:                MYREC r;        MYREC *r;   MYREC *r;
  r                     &r              r           r
  r[F]                  (&r)->F         (r)->F      (r)->F

[10]MYREC rs:           MYREC rs[10];   MYREC *rs;  MYREC *rs;
  rs                    rs              rs          rs
  rs[i]                 &rs[i]          &rs[i]      &rs[i]
  rs[i][F]              (&rs[i])->F     (&rs[i])->F (&rs[i])->F
                           -- depending on what F is -- if it's another record...

CHAN OF INT c:          Channel c;                  Channel *c;
  c                     &c                          c

[10]CHAN OF INT cs:     Channel* cs[10];            Channel **cs;
  cs                    cs                          cs
  cs[i]                 cs[i]                       cs[i]

I suspect there's probably a nicer way of doing this, but as a translation of
the above table this isn't too horrible...
-}
-- | Generate C code for a variable.
cgenVariable :: A.Variable -> CGen ()
cgenVariable = cgenVariable' True

-- | Generate C code for a variable without doing any range checks.
cgenVariableUnchecked :: A.Variable -> CGen ()
cgenVariableUnchecked = cgenVariable' False

cgenVariable' :: Bool -> A.Variable -> CGen ()
cgenVariable' checkValid v
  = do (cg, n) <- inner 0 v Nothing
       addPrefix cg n
  where
    -- The general plan here is to generate the variable, while also
    -- putting in the right prefixes (&/*/**/***/etc).
    -- We use an "indirection level" to record the prefix needed.
    -- 0 means no prefix, -1 means &, 1 means *, 2 means **, etc
    
    -- For arrays, we must pass through the inner type of the array
    -- so that we can add the appropriate prefixes before the array
    -- name.  That is, we make sure we write (&foo[0]), not
    -- (&foo)[0]
  
    inner :: Int -> A.Variable -> Maybe A.Type -> CGen (CGen (), Int)
    inner ind (A.Variable _ n) mt
      = do amN <- abbrevModeOfName n
           (am,t) <- case (amN,mt) of 
                       -- Channel arrays are special, because they are arrays of abbreviations:
                       (_, Just t'@(A.Chan {})) -> return (A.Abbrev, t')
                       -- If we are dealing with an array element, treat it as if it had the original abbreviation mode,
                       -- regardless of the abbreviation mode of the array:
                       (_, Just t') -> return (A.Original, t')
                       (am,Nothing) -> do t <- typeOfName n
                                          return (am, t)
           let ind' = case (am, t, indirectedType t) of
                        -- For types that are referred to by pointer (such as records)
                        -- we need to take the address:
                        (A.Original, _, True) -> ind - 1
                        -- If the type is referred to by pointer but is already abbreviated,
                        -- no need to change the indirection:
                        (_, _, True) -> ind                        
                        -- Undirected channels will already have been handled, so this is for directed:
                        (A.Abbrev, A.Chan {}, _) -> ind
                        -- Abbreviations of arrays are pointers, just like arrays, so no
                        -- need for a * operator:
                        (A.Abbrev, A.Array {}, _) -> ind
                        (A.Abbrev, _, _) -> ind + 1
                        _ -> ind
           return (genName n, ind')
    inner ind (A.DerefVariable _ v) mt
      = do (A.Mobile t) <- typeOfVariable v
           case t of
             A.Array {} -> inner ind v mt
             A.Record {} -> inner ind v mt
             _ -> inner (ind+1) v mt
    inner ind (A.DirectedVariable _ dir v) mt
      = do (cg,n) <- (inner ind v mt)           
           return (call genDirectedVariable (addPrefix cg n) dir, 0)
    inner ind sv@(A.SubscriptedVariable _ (A.Subscript _ _) _) mt
      = do let (es, v) = collectSubs sv
           t <- typeOfVariable sv
           (cg, n) <- inner ind v (Just t)
           return (cg >> call genArraySubscript checkValid v es, n)
    inner ind sv@(A.SubscriptedVariable _ (A.SubscriptField m n) v) mt
        =  do (cg, ind') <- inner ind v mt
              t <- typeOfVariable sv
              let outerInd :: Int
                  outerInd = if indirectedType t then -1 else 0
              return (addPrefix (addPrefix cg ind' >> tell ["->"] >> genName n) outerInd, 0)
    inner ind (A.SubscriptedVariable m (A.SubscriptFromFor m' start _) v) mt
        = inner ind (A.SubscriptedVariable m (A.Subscript m' start) v) mt
    inner ind (A.SubscriptedVariable m (A.SubscriptFrom m' start) v) mt
        = inner ind (A.SubscriptedVariable m (A.Subscript m' start) v) mt
    inner ind (A.SubscriptedVariable m (A.SubscriptFor m' _) v) mt
        = inner ind (A.SubscriptedVariable m (A.Subscript m' (makeConstant m' 0)) v) mt
   
    indirectedType :: A.Type -> Bool
    indirectedType (A.Record {}) = True
    indirectedType (A.Chan A.DirUnknown _ _) = True
    indirectedType _ = False

    addPrefix :: CGen () -> Int -> CGen ()
    addPrefix cg 0 = cg
    addPrefix cg n = tell ["(", getPrefix n] >> cg >> tell [")"]

    getPrefix :: Int -> String
    getPrefix 0 = ""
    getPrefix (-1) = "&"
    getPrefix n = if n > 0 then replicate n '*' else "#error Negative prefix lower than -1"

    -- | Collect all the plain subscripts on a variable, so we can combine them.
    collectSubs :: A.Variable -> ([A.Expression], A.Variable)
    collectSubs (A.SubscriptedVariable _ (A.Subscript _ e) v)
        = (es' ++ [e], v')
      where
        (es', v') = collectSubs v
    collectSubs v = ([], v)


cgenDirectedVariable :: CGen () -> A.Direction -> CGen ()
cgenDirectedVariable var _ = var

cgenArraySubscript :: Bool -> A.Variable -> [A.Expression] -> CGen ()
cgenArraySubscript checkValid v es
    =  do t <- typeOfVariable v
          let numDims = case t of A.Array ds _ -> length ds
          tell ["["]
          sequence_ $ intersperse (tell ["+"]) $ genPlainSub v es [0..(numDims - 1)]
          tell ["]"]
  where
    -- | Generate the individual offsets that need adding together to find the
    -- right place in the array.
    -- FIXME This is obviously not the best way to factor this, but I figure a
    -- smart C compiler should be able to work it out...
    genPlainSub :: A.Variable -> [A.Expression] -> [Int] -> [CGen ()]
    genPlainSub _ [] _ = []
    genPlainSub v (e:es) (sub:subs)
        = gen : genPlainSub v es subs
      where
        gen = sequence_ $ intersperse (tell ["*"]) $ genSub : genChunks
        genSub
            = if checkValid
                then do tell ["occam_check_index("]
                        call genExpression e
                        tell [","]
                        call genVariable v
                        call genSizeSuffix (show sub)
                        tell [","]
                        genMeta (findMeta e)
                        tell [")"]
                else call genExpression e
        genChunks = [call genVariable v >> call genSizeSuffix (show i) | i <- subs]
--}}}

--{{{  expressions
cgenExpression :: A.Expression -> CGen ()
cgenExpression (A.Monadic m op e) = call genMonadic m op e
cgenExpression (A.Dyadic m op e f) = call genDyadic m op e f
cgenExpression (A.MostPos m t) = call genTypeSymbol "mostpos" t
cgenExpression (A.MostNeg m t) = call genTypeSymbol "mostneg" t
--cgenExpression (A.SizeType m t)
cgenExpression (A.SizeExpr m e)
    =  do call genExpression e
          call genSizeSuffix "0"
cgenExpression (A.SizeVariable m v)
    =  do call genVariable v
          call genSizeSuffix "0"
cgenExpression (A.Conversion m cm t e) = call genConversion m cm t e
cgenExpression (A.ExprVariable m v) = call genVariable v
cgenExpression (A.Literal _ t lr) = call genLiteral lr t
cgenExpression (A.True m) = tell ["true"]
cgenExpression (A.False m) = tell ["false"]
--cgenExpression (A.FunctionCall m n es)
cgenExpression (A.IntrinsicFunctionCall m s es) = call genIntrinsicFunction m s es
--cgenExpression (A.SubscriptedExpr m s e)
--cgenExpression (A.BytesInExpr m e)
cgenExpression (A.BytesInType m t) = call genBytesIn m t (Left False)
--cgenExpression (A.OffsetOf m t n)
--cgenExpression (A.ExprConstr {})
cgenExpression (A.AllocMobile m t me) = call genAllocMobile m t me
cgenExpression t = call genMissing $ "genExpression " ++ show t

cgenSizeSuffix :: String -> CGen ()
cgenSizeSuffix dim = tell ["_sizes[", dim, "]"]

cgenTypeSymbol :: String -> A.Type -> CGen ()
cgenTypeSymbol s t
 = do f <- fget getScalarType
      case f t of
        Just ct -> tell ["occam_", s, "_", ct]
        Nothing -> call genMissingC $ formatCode "genTypeSymbol %" t

cgenIntrinsicFunction :: Meta -> String -> [A.Expression] -> CGen ()
cgenIntrinsicFunction m s es
    =  do tell ["occam_", s, " ("]
          sequence [call genExpression e >> genComma | e <- es]
          genMeta m
          tell [")"]
--}}}

--{{{  operators
cgenSimpleMonadic :: String -> A.Expression -> CGen ()
cgenSimpleMonadic s e
    =  do tell ["(", s]
          call genExpression e
          tell [")"]

cgenFuncMonadic :: Meta -> String -> A.Expression -> CGen ()
cgenFuncMonadic m s e
    =  do t <- typeOfExpression e
          call genTypeSymbol s t
          tell [" ("]
          call genExpression e
          tell [", "]
          genMeta m
          tell [")"]

cgenMonadic :: Meta -> A.MonadicOp -> A.Expression -> CGen ()
cgenMonadic m A.MonadicSubtr e = call genFuncMonadic m "negate" e
cgenMonadic _ A.MonadicMinus e = call genSimpleMonadic "-" e
cgenMonadic _ A.MonadicBitNot e = call genSimpleMonadic "~" e
cgenMonadic _ A.MonadicNot e = call genSimpleMonadic "!" e

cgenSimpleDyadic :: String -> A.Expression -> A.Expression -> CGen ()
cgenSimpleDyadic s e f
    =  do tell ["("]
          call genExpression e
          tell [" ", s, " "]
          call genExpression f
          tell [")"]

cgenFuncDyadic :: Meta -> String -> A.Expression -> A.Expression -> CGen ()
cgenFuncDyadic m s e f
    =  do t <- typeOfExpression e
          call genTypeSymbol s t
          tell [" ("]
          call genExpression e
          tell [", "]
          call genExpression f
          tell [", "]
          genMeta m
          tell [")"]

cgenDyadic :: Meta -> A.DyadicOp -> A.Expression -> A.Expression -> CGen ()
cgenDyadic m A.Add e f = call genFuncDyadic m "add" e f
cgenDyadic m A.Subtr e f = call genFuncDyadic m "subtr" e f
cgenDyadic m A.Mul e f = call genFuncDyadic m "mul" e f
cgenDyadic m A.Div e f = call genFuncDyadic m "div" e f
cgenDyadic m A.Rem e f = call genFuncDyadic m "rem" e f
cgenDyadic m A.Plus e f = call genFuncDyadic m "plus" e f
cgenDyadic m A.Minus e f = call genFuncDyadic m "minus" e f
cgenDyadic m A.Times e f = call genFuncDyadic m "times" e f
cgenDyadic m A.LeftShift e f = call genFuncDyadic m "lshift" e f
cgenDyadic m A.RightShift e f = call genFuncDyadic m "rshift" e f
cgenDyadic _ A.BitAnd e f = call genSimpleDyadic "&" e f
cgenDyadic _ A.BitOr e f = call genSimpleDyadic "|" e f
cgenDyadic _ A.BitXor e f = call genSimpleDyadic "^" e f
cgenDyadic _ A.And e f = call genSimpleDyadic "&&" e f
cgenDyadic _ A.Or e f = call genSimpleDyadic "||" e f
cgenDyadic _ A.Eq e f = call genSimpleDyadic "==" e f
cgenDyadic _ A.NotEq e f = call genSimpleDyadic "!=" e f
cgenDyadic _ A.Less e f = call genSimpleDyadic "<" e f
cgenDyadic _ A.More e f = call genSimpleDyadic ">" e f
cgenDyadic _ A.LessEq e f = call genSimpleDyadic "<=" e f
cgenDyadic _ A.MoreEq e f = call genSimpleDyadic ">=" e f
--}}}

--{{{  input/output items
cgenInputItem :: A.Variable -> A.InputItem -> CGen ()
cgenInputItem c (A.InCounted m cv av)
    =  do call genInputItem c (A.InVariable m cv)
          t <- typeOfVariable av
          tell ["ChanIn("]
          call genVariable c
          tell [","]
          fst $ abbrevVariable A.Abbrev t av
          tell [","]
          subT <- trivialSubscriptType m t
          call genVariable cv
          tell ["*"]
          call genBytesIn m subT (Right av)
          tell [");"]
cgenInputItem c (A.InVariable m v)
    =  do t <- typeOfVariable v
          let rhs = fst $ abbrevVariable A.Abbrev t v
          case t of
            A.Int ->
              do tell ["ChanInInt("]
                 call genVariable c
                 tell [","]
                 rhs
                 tell [");"]
            _ ->
              do tell ["ChanIn("]
                 call genVariable c
                 tell [","]
                 rhs
                 tell [","]
                 call genBytesIn m t (Right v)
                 tell [");"]

cgenOutputItem :: A.Variable -> A.OutputItem -> CGen ()
cgenOutputItem c (A.OutCounted m ce ae)
    =  do call genOutputItem c (A.OutExpression m ce)
          t <- typeOfExpression ae
          case ae of
            A.ExprVariable m v ->
              do tell ["ChanOut("]
                 call genVariable c
                 tell [","]
                 fst $ abbrevVariable A.Abbrev t v
                 tell [","]
                 subT <- trivialSubscriptType m t
                 call genExpression ce
                 tell ["*"]
                 call genBytesIn m subT (Right v)
                 tell [");"]
cgenOutputItem c (A.OutExpression m e)
    =  do t <- typeOfExpression e
          case (t, e) of
            (A.Int, _) ->
              do tell ["ChanOutInt("]
                 call genVariable c
                 tell [","]
                 call genExpression e
                 tell [");"]
            (_, A.ExprVariable _ v) ->
              do tell ["ChanOut("]
                 call genVariable c
                 tell [","]
                 fst $ abbrevVariable A.Abbrev t v
                 tell [","]
                 call genBytesIn m t (Right v)
                 tell [");"]
--}}}

--{{{  replicators
cgenReplicator :: A.Replicator -> CGen () -> CGen ()
cgenReplicator rep body
    =  do tell ["for("]
          call genReplicatorLoop rep
          tell ["){"]
          body
          tell ["}"]

isZero :: A.Expression -> Bool
isZero (A.Literal _ A.Int (A.IntLiteral _ "0")) = True
isZero _ = False

cgenReplicatorLoop :: A.Replicator -> CGen ()
cgenReplicatorLoop (A.For m index base count)
    = if isZero base
        then simple
        else general
  where
    simple :: CGen ()
    simple
        =  do tell ["int "]
              genName index
              tell ["=0;"]
              genName index
              tell ["<"]
              call genExpression count
              tell [";"]
              genName index
              tell ["++"]

    general :: CGen ()
    general
        =  do counter <- makeNonce "replicator_count"
              tell ["int ", counter, "="]
              call genExpression count
              tell [","]
              genName index
              tell ["="]
              call genExpression base
              tell [";", counter, ">0;", counter, "--,"]
              genName index
              tell ["++"]

--}}}

--{{{  abbreviations
-- FIXME: This code is horrible, and I can't easily convince myself that it's correct.

cgenSlice :: A.Variable -> A.Expression -> A.Expression -> [A.Dimension] -> (CGen (), A.Name -> CGen ())
cgenSlice v@(A.SubscriptedVariable _ _ (A.Variable _ on)) start count ds
       -- We need to disable the index check here because we might be taking
       -- element 0 of a 0-length array -- which is valid.
    = (tell ["&"] >> call genVariableUnchecked v,
       call genArraySize False
                    (do genLeftB
                        tell ["occam_check_slice("]
                        call genExpression start
                        tell [","]
                        call genExpression count
                        tell [","]
                        genName on
                        tell ["_sizes[0],"]
                        genMeta (findMeta count)
                        tell [")"]
                        sequence_ [do tell [","]
                                      genName on
                                      tell ["_sizes[", show i, "]"]
                                   | i <- [1..(length ds - 1)]]
                        genRightB
                    ))

cgenArraySize :: Bool -> CGen () -> A.Name -> CGen ()
cgenArraySize isPtr size n
    = if isPtr
        then do tell ["const int*"]
                genName n
                tell ["_sizes="]
                size
                tell [";"]
        else do tell ["const int "]
                genName n
                tell ["_sizes[]="]
                size
                tell [";"]

noSize :: A.Name -> CGen ()
noSize n = return ()

cgenVariableAM :: A.Variable -> A.AbbrevMode -> CGen ()
cgenVariableAM v am
    =  do when (am == A.Abbrev) $ tell ["&"]
          call genVariable v

-- | Generate the right-hand side of an abbreviation of a variable.
abbrevVariable :: A.AbbrevMode -> A.Type -> A.Variable -> (CGen (), A.Name -> CGen ())
abbrevVariable am (A.Array _ _) v@(A.SubscriptedVariable _ (A.Subscript _ _) _)
    = (tell ["&"] >> call genVariable v, genAASize v 0)
  where
        genAASize :: A.Variable -> Integer -> A.Name -> CGen ()
        genAASize (A.SubscriptedVariable _ (A.Subscript _ _) v) arg
            = genAASize v (arg + 1)
        genAASize (A.Variable _ on) arg
            = call genArraySize True
                       (tell ["&"] >> genName on >> tell ["_sizes[", show arg, "]"])
        genAASize (A.DirectedVariable _ _ v)  arg
            = const $ call genMissing "Cannot abbreviate a directed variable as an array"
                
abbrevVariable am (A.Array ds _) v@(A.SubscriptedVariable _ (A.SubscriptFromFor _ start count) _)
    = call genSlice v start count ds
abbrevVariable am (A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFrom _ start) v')
    = call genSlice v start (A.Dyadic m A.Minus (A.SizeExpr m (A.ExprVariable m v')) start) ds
abbrevVariable am (A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFor _ count) _)
    = call genSlice v (makeConstant m 0) count ds
abbrevVariable am (A.Array _ _) v
    = (call genVariable v, call genArraySize True (call genVariable v >> tell ["_sizes"]))
abbrevVariable am (A.Chan {}) v
    = (call genVariable v, noSize)
abbrevVariable am (A.Record _) v
    = (call genVariable v, noSize)
abbrevVariable am t v
    = (call genVariableAM v am, noSize)

-- | Generate the size part of a RETYPES\/RESHAPES abbrevation of a variable.
cgenRetypeSizes :: Meta -> A.Type -> A.Name -> A.Type -> A.Variable -> CGen ()
cgenRetypeSizes _ (A.Chan {}) _ (A.Chan {}) _ = return ()
cgenRetypeSizes m destT destN srcT srcV
    =     let size = do tell ["occam_check_retype("]
                        call genBytesIn m srcT (Right srcV)
                        tell [","]
                        call genBytesIn m destT (Left True)
                        tell [","]
                        genMeta m
                        tell [")"] in
          case destT of
            -- An array -- figure out the genMissing dimension, if there is one.
            A.Array destDS _ ->
              do let free = listToMaybe (indexOfFreeDimensions destDS)
                 case free of
                   -- No free dimensions; check the complete array matches in size.
                   Nothing ->
                     do tell ["if("]
                        size
                        tell ["!=1){"]
                        call genStop m "array size mismatch in RETYPES"
                        tell ["}"]
                   _ -> return ()

                 let dims = [case d of
                               A.UnknownDimension ->
                                 -- Unknown dimension -- insert it.
                                 case free of
                                   Just _ -> size
                                   Nothing ->
                                     dieP m "genRetypeSizes expecting free dimension"
                               A.Dimension n -> tell [show n]
                             | d <- destDS]
                 call genArraySize False (genLeftB >> seqComma dims >> genRightB) destN

            -- Not array; just check the size is 1.
            _ ->
              do tell ["if("]
                 size
                 tell ["!=1){"]
                 call genStop m "size mismatch in RETYPES"
                 tell ["}"]

-- | Generate the right-hand side of an abbreviation of an expression.
abbrevExpression :: A.AbbrevMode -> A.Type -> A.Expression -> (CGen (), A.Name -> CGen ())
abbrevExpression am t@(A.Array _ _) e
    = case e of
        A.ExprVariable _ v -> abbrevVariable am t v
        A.Literal _ t@(A.Array _ _) r -> (call genExpression e, call declareArraySizes t)
        _ -> bad
  where
    bad = (call genMissing "array expression abbreviation", noSize)
abbrevExpression am _ e
    = (call genExpression e, noSize)
--}}}

--{{{  specifications
cgenSpec :: A.Specification -> CGen () -> CGen ()
cgenSpec spec body
    =  do call introduceSpec spec
          body
          call removeSpec spec

-- | Generate a declaration of a new variable.
cgenDeclaration :: A.Type -> A.Name -> Bool -> CGen ()
cgenDeclaration at@(A.Array ds t) n False
    =  do call genType t
          tell [" "]
          case t of
            A.Chan A.DirUnknown _ _ ->
              do genName n
                 tell ["_storage"]
                 call genFlatArraySize ds
                 tell [";"]
                 call genType t
                 tell ["* "]
            _ -> return ()
          call genArrayStoreName n
          call genFlatArraySize ds
          tell [";"]
          call declareArraySizes at n
cgenDeclaration (A.Array ds t) n True
    =  do call genType t
          tell [" "]
          call genArrayStoreName n
          call genFlatArraySize ds
          tell [";"]
          tell ["int "]
          genName n
          tell ["_sizes[",show $ length ds,"];"]
cgenDeclaration t n _
    =  do call genType t
          tell [" "]
          genName n
          tell [";"]

-- | Generate the size of the C array that an occam array of the given
-- dimensions maps to.
cgenFlatArraySize :: [A.Dimension] -> CGen ()
cgenFlatArraySize ds
    =  do tell ["["]
          sequence $ intersperse (tell ["*"])
                                 [case d of A.Dimension n -> tell [show n] | d <- ds]
          tell ["]"]

-- | Declare an _sizes array for a variable.
cdeclareArraySizes :: A.Type -> A.Name -> CGen ()
cdeclareArraySizes t name
    = call genArraySize False (call genArraySizesLiteral name t) name

-- | Generate a C literal to initialise an _sizes array with, where all the
-- dimensions are fixed.
cgenArraySizesLiteral :: A.Name -> A.Type -> CGen ()
cgenArraySizesLiteral n (A.Array ds _)
    = genLeftB >> seqComma dims >> genRightB
  where
    dims :: [CGen ()]
    dims = [case d of
              A.Dimension n -> tell [show n]
              _ -> dieP (findMeta n) "unknown dimension in array type"
            | d <- ds]

-- | Initialise an item being declared.
cdeclareInit :: Meta -> A.Type -> A.Variable -> Maybe A.Expression -> Maybe (CGen ())
cdeclareInit _ (A.Chan A.DirUnknown _ _) var _
    = Just $ do tell ["ChanInit("]
                call genVariableUnchecked var
                tell [");"]
cdeclareInit m t@(A.Array ds t') var _
    = Just $ do case t' of
                  A.Chan A.DirUnknown _ _ ->
                    do tell ["tock_init_chan_array("]
                       call genVariableUnchecked var
                       tell ["_storage,"]
                       call genVariableUnchecked var
                       tell [","]
                       sequence_ $ intersperse (tell ["*"]) [case dim of A.Dimension d -> tell [show d] | dim <- ds]
                       tell [");"]
                  _ -> return ()
                fdeclareInit <- fget declareInit
                init <- return (\sub -> fdeclareInit m t' (sub var) Nothing)
                call genOverArray m var init
cdeclareInit m rt@(A.Record _) var _
    = Just $ do fs <- recordFields m rt
                sequence_ [initField t (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
  where
    initField :: A.Type -> A.Variable -> CGen ()
    -- An array as a record field; we must initialise the sizes.
    initField t@(A.Array ds _) v
        =  do sequence_ [do call genVariableUnchecked v
                            call genSizeSuffix (show i) 
                            tell ["=", show n, ";"]
                         | (i, A.Dimension n) <- zip [0..(length ds - 1)] ds]
              fdeclareInit <- fget declareInit
              doMaybe $ fdeclareInit m t v Nothing
    initField t v = do fdeclareInit <- fget declareInit
                       doMaybe $ fdeclareInit m t v Nothing
cdeclareInit m _ v (Just e)
    = Just $ call genAssign m [v] $ A.ExpressionList m [e]
cdeclareInit _ _ _ _ = Nothing

-- | Free a declared item that's going out of scope.
cdeclareFree :: Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cdeclareFree _ _ _ = Nothing

{-
                  Original        Abbrev
INT x IS y:       int *x = &y;    int *x = &(*y);
[]INT xs IS ys:   int *xs = ys;   int *xs = ys;
                  const int xs_sizes[] = ys_sizes;

CHAN OF INT c IS d:       Channel *c = d;

[10]CHAN OF INT cs:       Channel tmp[10];
                          Channel *cs[10];
                          for (...) { cs[i] = &tmp[i]; ChanInit(cs[i]); }
                          const int cs_sizes[] = { 10 };
[]CHAN OF INT ds IS cs:   Channel **ds = cs;
                          const int *ds_sizes = cs_sizes;
-}
cintroduceSpec :: A.Specification -> CGen ()
cintroduceSpec (A.Specification m n (A.Declaration _ t init))
    = do call genDeclaration t n False
         fdeclareInit <- fget declareInit
         case fdeclareInit m t (A.Variable m n) init of
           Just p -> p
           Nothing -> return ()
cintroduceSpec (A.Specification _ n (A.Is _ am t v))
    =  do let (rhs, rhsSizes) = abbrevVariable am t v
          call genDecl am t n
          tell ["="]
          rhs
          tell [";"]
          rhsSizes n
cintroduceSpec (A.Specification _ n (A.IsExpr _ am t e))
    =  do let (rhs, rhsSizes) = abbrevExpression am t e
          case (am, t, e) of
            (A.ValAbbrev, A.Array _ ts, A.Literal _ _ _) ->
              -- For "VAL []T a IS [vs]:", we have to use [] rather than * in the
              -- declaration, since you can't say "int *foo = {vs};" in C.
              do tell ["const "]
                 call genType ts
                 tell [" "]
                 genName n
                 tell ["[] = "]
                 rhs
                 tell [";\n"]
                 rhsSizes n
            (A.ValAbbrev, A.Record _, A.Literal _ _ _) ->
              -- Record literals are even trickier, because there's no way of
              -- directly writing a struct literal in C that you can use -> on.
              do tmp <- makeNonce "record_literal"
                 tell ["const "]
                 call genType t
                 tell [" ", tmp, " = "]
                 rhs
                 tell [";\n"]
                 call genDecl am t n
                 tell [" = &", tmp, ";\n"]
                 rhsSizes n
            _ ->
              do call genDecl am t n
                 tell [" = "]
                 rhs
                 tell [";\n"]
                 rhsSizes n
cintroduceSpec (A.Specification _ n (A.IsChannelArray _ (A.Array _ c) cs))
    =  do call genType c        
          tell ["*"]
          call genArrayStoreName n
          tell ["[]={"]
          seqComma (map (call genVariable) cs)
          tell ["};"]
          call declareArraySizes (A.Array [A.Dimension $ length cs] c) n
cintroduceSpec (A.Specification _ _ (A.DataType _ _)) = return ()
cintroduceSpec (A.Specification _ _ (A.RecordType _ _ _)) = return ()
cintroduceSpec (A.Specification _ n (A.Protocol _ _)) = return ()
cintroduceSpec (A.Specification _ n (A.ProtocolCase _ ts))
    =  do tell ["typedef enum{"]
          seqComma [genName tag >> tell ["_"] >> genName n | (tag, _) <- ts]
          -- You aren't allowed to have an empty enum.
          when (ts == []) $
            tell ["empty_protocol_"] >> genName n
          tell ["}"]
          genName n
          tell [";"]
cintroduceSpec (A.Specification _ n (A.Proc _ sm fs p))
    =  do call genSpecMode sm
          tell ["void "]
          genName n
          tell [" (Process *me"]
          call genFormals fs
          tell [") {\n"]
          call genProcess p
          tell ["}\n"]
cintroduceSpec (A.Specification _ n (A.Retypes m am t v))
    =  do origT <- typeOfVariable v
          let (rhs, _) = abbrevVariable A.Abbrev origT v
          call genDecl am t n
          tell ["="]
          -- For scalar types that are VAL abbreviations (e.g. VAL INT64),
          -- we need to dereference the pointer that abbrevVariable gives us.
          let deref = case (am, t) of
                        (_, A.Array _ _) -> False
                        (_, A.Chan {}) -> False
                        (_, A.Record {}) -> False
                        (A.ValAbbrev, _) -> True
                        _ -> False
          when deref $ tell ["*"]
          tell ["("]
          call genDeclType am t
          when deref $ tell ["*"]
          tell [")"]
          rhs
          tell [";"]
          call genRetypeSizes m t n origT v
--cintroduceSpec (A.Specification _ n (A.RetypesExpr _ am t e))
cintroduceSpec n = call genMissing $ "introduceSpec " ++ show n

cgenRecordTypeSpec :: A.Name -> Bool -> [(A.Name, A.Type)] -> CGen ()
cgenRecordTypeSpec n b fs
    =  do tell ["typedef struct{"]
          sequence_ [call genDeclaration t n True | (n, t) <- fs]
          tell ["}"]
          when b $ tell [" occam_struct_packed "]
          genName n
          tell [";"]


cgenForwardDeclaration :: A.Specification -> CGen ()
cgenForwardDeclaration (A.Specification _ n (A.Proc _ sm fs _))
    =  do call genSpecMode sm
          tell ["void "]
          genName n
          tell [" (Process *me"]
          call genFormals fs
          tell [");"]
cgenForwardDeclaration (A.Specification _ n (A.RecordType _ b fs))
    = call genRecordTypeSpec n b fs
cgenForwardDeclaration _ = return ()

cremoveSpec :: A.Specification -> CGen ()
cremoveSpec (A.Specification m n (A.Declaration _ t _))
 = do fdeclareFree <- fget declareFree
      case fdeclareFree m t var of
        Just p -> p
        Nothing -> return ()
  where
    var = A.Variable m n
cremoveSpec _ = return ()

cgenSpecMode :: A.SpecMode -> CGen ()
cgenSpecMode A.PlainSpec = return ()
cgenSpecMode A.InlineSpec = tell ["inline "]
--}}}

--{{{  actuals/formals
prefixComma :: [CGen ()] -> CGen ()
prefixComma cs = sequence_ [genComma >> c | c <- cs]

cgenActuals :: [A.Actual] -> CGen ()
cgenActuals as = prefixComma (map (call genActual) as)

cgenActual :: A.Actual -> CGen ()
cgenActual actual
    = case actual of
        A.ActualExpression t e ->
          case (t, e) of
            (A.Array _ _, A.ExprVariable _ v) ->
              do call genVariable v
                 tell [","]
                 call genVariable v
                 tell ["_sizes"]
            _ -> call genExpression e
        A.ActualVariable am t v ->
          case t of
            A.Array _ _ ->
              do call genVariable v
                 tell [","]
                 call genVariable v
                 tell ["_sizes"]
            _ -> fst $ abbrevVariable am t v

numCArgs :: [A.Actual] -> Int
numCArgs [] = 0
numCArgs (A.ActualVariable _ (A.Array _ _) _:fs) = 2 + numCArgs fs
numCArgs (A.ActualExpression (A.Array _ _) _:fs) = 2 + numCArgs fs
numCArgs (_:fs) = 1 + numCArgs fs

cgenFormals :: [A.Formal] -> CGen ()
cgenFormals fs = prefixComma (map (call genFormal) fs)

cgenFormal :: A.Formal -> CGen ()
cgenFormal (A.Formal am t n)
    = case t of
        A.Array _ t' ->
          do call genDecl am t n
             tell [", const int *"]
             genName n
             tell ["_sizes"]
        _ -> call genDecl am t n
--}}}

--{{{  processes
cgenProcess :: A.Process -> CGen ()
cgenProcess p = case p of
  A.Assign m vs es -> call genAssign m vs es
  A.Input m c im -> call genInput c im
  A.Output m c ois -> call genOutput c ois
  A.OutputCase m c t ois -> call genOutputCase c t ois
  A.GetTime m v -> call genGetTime m v
  A.Wait m wm e -> call genWait wm e
  A.Skip m -> tell ["/* skip */\n"]
  A.Stop m -> call genStop m "STOP process"
  A.Seq _ s -> call genSeq s
  A.If m s -> call genIf m s
  A.Case m e s -> call genCase m e s
  A.While m e p -> call genWhile e p
  A.Par m pm s -> call genPar pm s
  -- PROCESSOR does nothing special.
  A.Processor m e p -> call genProcess p
  A.Alt m b s -> call genAlt b s
  A.ProcCall m n as -> call genProcCall n as
  A.IntrinsicProcCall m s as -> call genIntrinsicProc m s as

--{{{  assignment
cgenAssign :: Meta -> [A.Variable] -> A.ExpressionList -> CGen ()
cgenAssign m [v] (A.ExpressionList _ [e])
    = do t <- typeOfVariable v
         f <- fget getScalarType
         case f t of
           Just _ -> doAssign v e
           Nothing -> case t of
             -- Assignment of channel-ends, but not channels, is possible (at least in Rain):
             A.Chan A.DirInput _ _ -> doAssign v e
             A.Chan A.DirOutput _ _ -> doAssign v e
             _ -> call genMissingC $ formatCode "assignment of type %" t
  where
    doAssign :: A.Variable -> A.Expression -> CGen ()
    doAssign v e
        = do call genVariable v
             tell ["="]
             call genExpression e
             tell [";"]
cgenAssign m _ _ = call genMissing "Cannot perform assignment with multiple destinations or multiple sources"

--}}}
--{{{  input
cgenInput :: A.Variable -> A.InputMode -> CGen ()
cgenInput c im
    =  do case im of
            A.InputTimerRead m (A.InVariable m' v) -> call genTimerRead c v
            A.InputTimerAfter m e -> call genTimerWait e
            A.InputSimple m is -> sequence_ $ map (call genInputItem c) is
            _ -> call genMissing $ "genInput " ++ show im

cgenTimerRead :: A.Variable -> A.Variable -> CGen ()
cgenTimerRead c v
    =  do tell ["ProcTime (&"]
          call genVariable c
          tell [");\n"]
          call genVariable v
          tell [" = "]
          call genVariable c
          tell [";\n"]

cgenTimerWait :: A.Expression -> CGen ()
cgenTimerWait e
    =  do tell ["ProcTimeAfter("]
          call genExpression e
          tell [");"]

cgenGetTime :: Meta -> A.Variable -> CGen ()
cgenGetTime m v
    =  do tell ["ProcTime(&"]
          call genVariable v
          tell [");"]

cgenWait :: A.WaitMode -> A.Expression -> CGen ()
cgenWait A.WaitUntil e = call genTimerWait e
cgenWait A.WaitFor e
    =  do tell ["ProcAfter("]
          call genExpression e
          tell [");"]

--}}}
--{{{  output
cgenOutput :: A.Variable -> [A.OutputItem] -> CGen ()
cgenOutput c ois = sequence_ $ map (call genOutputItem c) ois

cgenOutputCase :: A.Variable -> A.Name -> [A.OutputItem] -> CGen ()
cgenOutputCase c tag ois
    =  do t <- typeOfVariable c
          let proto = case t of A.Chan _ _ (A.UserProtocol n) -> n
          tell ["ChanOutInt("]
          call genVariable c
          tell [","]
          genName tag
          tell ["_"]
          genName proto
          tell [");"]
          call genOutput c ois
--}}}
--{{{  stop
cgenStop :: Meta -> String -> CGen ()
cgenStop m s
    =  do tell ["occam_stop("]
          genMeta m
          tell [",\"", s, "\");"]
--}}}
--{{{  seq
cgenSeq :: A.Structured A.Process -> CGen ()
cgenSeq s = call genStructured s doP
  where
    doP _ p = call genProcess p
--}}}
--{{{  if
cgenIf :: Meta -> A.Structured A.Choice -> CGen ()
cgenIf m s
    =  do label <- makeNonce "if_end"
          tell ["/*",label,"*/"]
          genIfBody label s
          call genStop m "no choice matched in IF process"
          tell [label, ":;"]
  where
    genIfBody :: String -> A.Structured A.Choice -> CGen ()
    genIfBody label s = call genStructured s doC
      where
        doC m (A.Choice m' e p)
            = do tell ["if("]
                 call genExpression e
                 tell ["){"]
                 call genProcess p
                 tell ["goto ", label, ";"]
                 tell ["}"]
--}}}
--{{{  case
cgenCase :: Meta -> A.Expression -> A.Structured A.Option -> CGen ()
cgenCase m e s
    =  do tell ["switch("]
          call genExpression e
          tell ["){"]
          seenDefault <- genCaseBody (return ()) s
          when (not seenDefault) $
            do tell ["default:"]
               call genStop m "no option matched in CASE process"
          tell ["}"]
  where
    genCaseBody :: CGen () -> A.Structured A.Option -> CGen Bool
    genCaseBody coll (A.Spec _ spec s)
        = genCaseBody (call genSpec spec coll) s
    genCaseBody coll (A.Only _ (A.Option _ es p))
        =  do sequence_ [tell ["case "] >> call genExpression e >> tell [":"] | e <- es]
              tell ["{"]
              coll
              call genProcess p
              tell ["}break;"]
              return False
    genCaseBody coll (A.Only _ (A.Else _ p))
        =  do tell ["default:"]
              tell ["{"]
              coll
              call genProcess p
              tell ["}break;"]
              return True
    genCaseBody coll (A.Several _ ss)
        =  do seens <- mapM (genCaseBody coll) ss
              return $ or seens
--}}}
--{{{  while
cgenWhile :: A.Expression -> A.Process -> CGen ()
cgenWhile e p
    =  do tell ["while("]
          call genExpression e
          tell ["){"]
          call genProcess p
          tell ["}"]
--}}}
--{{{  par
cgenPar :: A.ParMode -> A.Structured A.Process -> CGen ()
cgenPar pm s
    =  do (size, _, _) <- constantFold $ addOne (sizeOfStructured s)
          pids <- makeNonce "pids"
          pris <- makeNonce "priorities"
          index <- makeNonce "i"
          when (pm == A.PriPar) $
            do tell ["int ", pris, "["]
               call genExpression size
               tell ["];\n"]
          tell ["Process *", pids, "["]
          call genExpression size
          tell ["];\n"]
          tell ["int ", index, " = 0;\n"]
          call genStructured s (createP pids pris index)
          tell [pids, "[", index, "] = NULL;\n"]
          tell ["if(",pids,"[0] != NULL){"] -- CIF seems to deadlock when you give ProcParList a list 
                                            -- beginning with NULL (i.e. with no processes)
          case pm of
            A.PriPar -> tell ["ProcPriParList (", pids, ", ", pris, ");\n"]
            _ -> tell ["ProcParList (", pids, ");\n"]
          tell ["}"]
          tell [index, " = 0;\n"]
          call genStructured s (freeP pids index)
  where
    createP pids pris index _ p
        = do when (pm == A.PriPar) $
               tell [pris, "[", index, "] = ", index, ";\n"]
             tell [pids, "[", index, "++] = "]
             genProcAlloc p
             tell [";\n"]
    freeP pids index _ _
        = do tell ["ProcAllocClean (", pids, "[", index, "++]);\n"]

    genProcAlloc :: A.Process -> CGen ()
    genProcAlloc (A.ProcCall m n as)
        =  do tell ["ProcAlloc ("]
              genName n
              let stackSize = nameString n ++ "_stack_size"
              tell [", ", stackSize, ", ", show $ numCArgs as]
              call genActuals as
              tell [")"]
    genProcAlloc p = call genMissing $ "genProcAlloc " ++ show p
--}}}
--{{{  alt
cgenAlt :: Bool -> A.Structured A.Alternative -> CGen ()
cgenAlt isPri s
    =  do tell ["AltStart ();\n"]
          tell ["{\n"]
          genAltEnable s
          tell ["}\n"]
          -- Like occ21, this is always a PRI ALT, so we can use it for both.
          tell ["AltWait ();\n"]
          id <- makeNonce "alt_id"
          tell ["int ", id, " = 0;\n"]
          tell ["{\n"]
          genAltDisable id s
          tell ["}\n"]
          fired <- makeNonce "alt_fired"
          tell ["int ", fired, " = AltEnd ();\n"]
          tell [id, " = 0;\n"]
          label <- makeNonce "alt_end"
          tell ["{\n"]
          genAltProcesses id fired label s
          tell ["}\n"]
          tell [label, ":\n;\n"]
  where
    genAltEnable :: A.Structured A.Alternative -> CGen ()
    genAltEnable s = call genStructured s doA
      where
        doA _ alt
            = case alt of
                A.Alternative _ c im _ -> doIn c im
                A.AlternativeCond _ e c im _ -> withIf e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf e $ tell ["AltEnableSkip ();\n"]
                --transformWaitFor should have removed all A.WaitFor guards (transforming them into A.WaitUntil):
                A.AlternativeWait _ A.WaitUntil e _ ->
                  do tell ["AltEnableTimer ( "]
                     call genExpression e
                     tell [" );\n"]

        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do tell ["AltEnableTimer ("]
                        call genExpression time
                        tell [");\n"]
                   _ ->
                     do tell ["AltEnableChannel ("]
                        call genVariable c
                        tell [");\n"]

    genAltDisable :: String -> A.Structured A.Alternative -> CGen ()
    genAltDisable id s = call genStructured s doA
      where
        doA _ alt
            = case alt of
                A.Alternative _ c im _ -> doIn c im
                A.AlternativeCond _ e c im _ -> withIf e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf e $ tell ["AltDisableSkip (", id, "++);\n"]
                A.AlternativeWait _ A.WaitUntil e _ ->
                     do tell ["AltDisableTimer (", id, "++, "]
                        call genExpression e
                        tell [");\n"]
        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do tell ["AltDisableTimer (", id, "++, "]
                        call genExpression time
                        tell [");\n"]
                   _ ->
                     do tell ["AltDisableChannel (", id, "++, "]
                        call genVariable c
                        tell [");\n"]

    genAltProcesses :: String -> String -> String -> A.Structured A.Alternative -> CGen ()
    genAltProcesses id fired label s = call genStructured s doA
      where
        doA _ alt
            = case alt of
                A.Alternative _ c im p -> doIn c im p
                A.AlternativeCond _ e c im p -> withIf e $ doIn c im p
                A.AlternativeSkip _ e p -> withIf e $ doCheck (call genProcess p)
                A.AlternativeWait _ _ _ p -> doCheck (call genProcess p)

        doIn c im p
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing "timer read in ALT"
                   A.InputTimerAfter _ _ -> doCheck (call genProcess p)
                   _ -> doCheck (call genInput c im >> call genProcess p)

        doCheck body
            = do tell ["if (", id, "++ == ", fired, ") {\n"]
                 body
                 tell ["goto ", label, ";\n"]
                 tell ["}\n"]

withIf :: A.Expression -> CGen () -> CGen ()
withIf cond body
    =  do tell ["if ("]
          call genExpression cond
          tell [") {\n"]
          body
          tell ["}\n"]
--}}}
--{{{  proc call
cgenProcCall :: A.Name -> [A.Actual] -> CGen ()
cgenProcCall n as
    =  do genName n
          tell [" (me"]
          call genActuals as
          tell [");\n"]
--}}}
--{{{  intrinsic procs
cgenIntrinsicProc :: Meta -> String -> [A.Actual] -> CGen ()
cgenIntrinsicProc m "ASSERT" [A.ActualExpression A.Bool e] = call genAssert m e
cgenIntrinsicProc _ s _ = call genMissing $ "intrinsic PROC " ++ s

cgenAssert :: Meta -> A.Expression -> CGen ()
cgenAssert m e
    =  do tell ["if (!"]
          call genExpression e
          tell [") {\n"]
          call genStop m "assertion failed"
          tell ["}\n"]
--}}}
--}}}

--{{{ mobiles
cgenAllocMobile :: Meta -> A.Type -> Maybe A.Expression -> CGen()
cgenAllocMobile m (A.Mobile t) Nothing = tell ["malloc("] >> call genBytesIn m t (Left False) >> tell [")"]
--TODO add a pass, just for C, that pulls out the initialisation expressions for mobiles
-- into a subsequent assignment
cgenAllocMobile _ _ _ = call genMissing "Mobile allocation with initialising-expression"

cgenClearMobile :: Meta -> A.Variable -> CGen ()
cgenClearMobile _ v
  = do tell ["if("]
       genVar
       tell ["!=NULL){free("]
       genVar
       tell [");"]
       genVar
       tell ["=NULL;}"]
  where
    genVar = call genVariable v

--}}}
