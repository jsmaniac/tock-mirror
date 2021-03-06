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

-- | Flatten nested declarations.
module Unnest (unnest, removeNesting) where

import Control.Monad.State
import Data.Generics (Data)
import Data.List
import qualified Data.Map as Map
import Data.Maybe

import qualified AST as A
import CompState
import Errors
import EvalConstants
import Pass
import qualified Properties as Prop
import Traversal
import Types
import Utils

unnest :: [Pass A.AST]
unnest =
      [ removeFreeNames
      , removeNesting
      ]

type NameMap = Map.Map String A.Name

type FreeNameM = State (Map.Map String A.Name)

type FreeNameOps = A.SpecType :-* A.Name :-* ExtOpMS BaseOpM

-- | Get the set of free names within a block of code.
freeNamesIn :: AlloyA t FreeNameOps BaseOpM => t -> NameMap
freeNamesIn = flip execState Map.empty . recurse
  where
    ops :: FreeNameOps FreeNameM
    ops = doSpecType :-* doName :-* opMS (ops, doStructured)

    recurse :: RecurseA FreeNameM FreeNameOps
    recurse = makeRecurseM ops
    descend :: DescendA FreeNameM FreeNameOps
    descend = makeDescendM ops
    
    doName :: A.Name -> FreeNameM A.Name
    doName n = modify (Map.insert (A.nameName n) n) >> return n

    doStructured :: (Data a, AlloyA (A.Structured a) BaseOpM FreeNameOps
                           , AlloyA (A.Structured a) FreeNameOps BaseOpM
                    )
      => A.Structured a -> FreeNameM (A.Structured a)
    doStructured x@(A.Spec _ spec s) = doSpec spec s >> return x
    doStructured s = descend s

    doSpec :: (AlloyA t BaseOpM FreeNameOps
              ,AlloyA t FreeNameOps BaseOpM) => A.Specification -> t -> FreeNameM ()
    doSpec (A.Specification _ n st) child
        = modify (Map.union $ Map.union fns $ Map.delete (A.nameName n) $ freeNamesIn child)
      where
        fns = freeNamesIn st

    doSpecType :: A.SpecType -> FreeNameM A.SpecType
    doSpecType x@(A.Proc _ _ fs p) = modify (Map.union $ Map.difference (freeNamesIn p) (freeNamesIn fs))
      >> return x
    doSpecType x@(A.Function _ _ _ fs vp) = modify (Map.union $ Map.difference (freeNamesIn vp) (freeNamesIn fs))
      >> return x
    doSpecType st = descend st

-- | Replace names.
--
-- This has to have extra cleverness due to a really nasty bug.  Array types can
-- have expressions as dimensions, and those expressions can contain free names
-- which are being replaced.  This is fine, but when that happens we need to update
-- CompState so that the type has the replaced name, not the old name.
replaceNames :: AlloyA t (TwoOpA A.Name A.Specification) BaseOpM => [(A.Name, A.Name)] -> t -> PassM t
replaceNames map = recurse
  where
    smap = Map.fromList [(A.nameName f, t) | (f, t) <- map]

    ops :: TwoOpA A.Name A.Specification PassM
    ops = doName :-* doSpecification :-* baseOpA

    recurse :: RecurseA PassM (TwoOpA A.Name A.Specification)
    recurse = makeRecurseM ops

    doName :: Transform A.Name
    doName n = return $ Map.findWithDefault n (A.nameName n) smap

    doSpecification :: Transform A.Specification
    doSpecification (A.Specification m n sp)
      = do prevT <- typeOfSpec sp
           n' <- doName n
           sp' <- recurse sp
           afterT <- typeOfSpec sp'
           -- The only way the type will change is if there was a name replace:
           when (prevT /= afterT) $
             modifyName n' $ \nd -> nd { A.ndSpecType = sp' }
           return $ A.Specification m n' sp'

-- | Turn free names in PROCs into arguments.
removeFreeNames :: PassOn2 A.Specification A.Process
removeFreeNames = pass "Convert free names to arguments"
  [Prop.mainTagged, Prop.parsWrapped, Prop.functionCallsRemoved]
  [Prop.freeNamesToArgs]
  (flip evalStateT Map.empty . applyBottomUpM2 doSpecification doProcess)
  where
    doSpecification :: A.Specification -> StateT (Map.Map String [A.Actual]) PassM A.Specification
    doSpecification (A.Specification m n st@(A.Proc mp sm fs (Just p))) =
          do -- If this is the top-level process, we shouldn't add new args --
             -- we know it's not going to be moved by removeNesting, so anything
             -- that it had in scope originally will still be in scope.
             ps <- getCompState
             when (null $ csMainLocals ps) (dieReport (Nothing,"No main process found"))
             let isTLP = (fst $ snd $ head $ csMainLocals ps) == n

             -- Figure out the free names.
             freeNames <- if isTLP
                            then return []
                            else filterM isFreeName
                                         (Map.elems $ freeNamesIn st)
             types <- mapM astTypeOf freeNames
             origAMs <- mapM abbrevModeOfName freeNames
             let ams = map makeAbbrevAM origAMs

             -- Generate and define new names to replace them with
             newNamesS <- sequence [makeNonce (A.nameMeta n) (A.nameName n) | n <- freeNames]
             let newNames = [on { A.nameName = nn } | (on, nn) <- zip freeNames newNamesS]
             onds <- mapM (\n -> lookupNameOrError n $ dieP mp $ "Could not find recorded type for free name: " ++ (show $ A.nameName n)) freeNames
             sequence_ [defineName nn (ond { A.ndName = A.nameName nn,
                                             A.ndAbbrevMode = am })
                        | (ond, nn, am) <- zip3 onds newNames ams]

             -- Add formals for each of the free names
             let newFs = [A.Formal am t n | (am, t, n) <- zip3 ams types newNames]
             st' <- lift $ replaceNames (zip freeNames newNames) p >>* (A.Proc mp sm (fs ++ newFs) . Just)
             let spec' = A.Specification m n st'

             -- Update the definition of the proc
             nameDef <- lookupName n
             lift $ defineName n (nameDef { A.ndSpecType = st' })

             -- Note that we should add extra arguments to calls of this proc
             -- when we find them
             let newAs = [case am of
                            A.Abbrev -> A.ActualVariable (A.Variable m n)
                            _ -> A.ActualExpression (A.ExprVariable m (A.Variable m n))
                          | (am, n) <- zip ams freeNames]
             debug $ "removeFreeNames: " ++ show n ++ " has new args " ++ show newAs
             when (newAs /= []) $
               modify $ Map.insert (A.nameName n) newAs

             return spec'
    doSpecification spec = return spec

    -- | Return whether a 'Name' could be considered a free name.
    --
    -- Unscoped and ghost names aren't.
    -- Things like data types and PROCs aren't, because they'll be the same
    -- for all instances of a PROC.
    -- Constants aren't, because they'll be pulled up anyway.
    isFreeName :: (Die m, CSM m) => A.Name -> m Bool
    isFreeName n
        =  do st <- specTypeOfName n
              isConst <- isConstantName n
              src <- nameSource n
              return $ isFreeST st && not (isConst || src == A.NamePredefined || src == A.NameExternal)
      where
        isFreeST :: A.SpecType -> Bool
        isFreeST st
            = case st of
                -- Declaration also covers PROC formals.
                A.Declaration {} -> True
                A.Is {} -> True
                A.Retypes {} -> True
                A.RetypesExpr {} -> True
                A.Rep {} -> True
                A.Forking {} -> True
                _ -> False

    -- | Add the extra arguments we recorded when we saw the definition.
    doProcess :: A.Process -> StateT (Map.Map String [A.Actual]) PassM A.Process
    doProcess p@(A.ProcCall m n as)
        =  do st <- get
              case Map.lookup (A.nameName n) st of
                Just add -> return $ A.ProcCall m n (as ++ add)
                Nothing -> return p
    doProcess p = return p

-- | Pull nested declarations to the top level.
removeNesting :: PassASTOnOps (ExtOpMS BaseOpM)
removeNesting = pass "Pull nested definitions to top level"
  [Prop.freeNamesToArgs]
  [Prop.nestedPulled]
  (passOnlyOnAST "removeNesting" $ \s ->
       do pushPullContext
          s' <- recurse s >>= applyPulled
          popPullContext
          return s')
  where
    ops :: ExtOpMSP BaseOpM
    ops = baseOpA `extOpMS` (ops, doStructured)


    recurse :: RecurseA PassM (ExtOpMS BaseOpM)
    recurse = makeRecurseM ops
    descend :: DescendA PassM (ExtOpMS BaseOpM)
    descend = makeDescendM ops

    doStructured :: TransformStructured (ExtOpMS BaseOpM)
    doStructured s@(A.Spec m spec subS)
        = do spec'@(A.Specification _ n st) <- recurse spec
             isConst <- isConstantName n
             if (isConst && not (abbrevRecord st)) || canPull st then
                 do debug $ "removeNesting: pulling up " ++ show n
                    addPulled $ (m, Left spec')
                    doStructured subS
               else descend s
    doStructured s = descend s

    canPull :: A.SpecType -> Bool
    canPull (A.Proc _ _ _ _) = True
    canPull (A.Function {}) = True
    canPull (A.RecordType _ _ _) = True
    canPull (A.Protocol _ _) = True
    canPull (A.ProtocolCase _ _) = True
    canPull _ = False

    -- C doesn't allow us to pull up pointers to records to the top-level
    abbrevRecord :: A.SpecType -> Bool
    abbrevRecord (A.Is _ _ (A.Record {}) _) = True
    abbrevRecord (A.Is _ _ (A.Array _ (A.Record {})) _) = True
    abbrevRecord _ = False
    

