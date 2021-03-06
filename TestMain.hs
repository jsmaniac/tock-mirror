{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008, 2009  University of Kent
Copyright (C) 2011  Adam Sampson <ats@offog.org>

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

-- | A module containing the 'main' function for the Tock test suite.  It currently runs tests from the following modules:
--
-- * "AnalyseAsmTest"
--
-- * "ArrayUsageCheckTest"
--
-- * "BackendPassesTest"
--
-- * "CheckTest"
--
-- * "CommonTest"
--
-- * "FlowGraphTest"
--
-- * "GenerateCTest"
--
-- * "OccamPassesTest"
--
-- * "OccamTypesTest"
--
-- * "ParseRainTest"
--
-- * "PassTest"
--
-- * "PreprocessOccamTest"
--
-- * "RainPassesTest"
--
-- * "RainTypesTest"
--
-- * "SimplifyAbbrevsTest"
--
-- * "SimplifyTypesTest"
--
-- * "StructureOccamTest"
--
-- * "UsageCheckTest"
module TestMain (main) where

import Control.Monad
import Data.List
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO
import Test.HUnit

import qualified AnalyseAsmTest (tests)
import qualified ArrayUsageCheckTest (vioqcTests)
import qualified BackendPassesTest (qcTests)
import qualified CheckTest (viotests)
import qualified CommonTest (tests)
import qualified FlowGraphTest (qcTests)
import qualified GenerateCTest (tests)
import qualified OccamPassesTest (tests)
import qualified OccamTypesTest (vioTests)
import qualified ParseRainTest (tests)
import qualified PassTest (tests)
import qualified PreprocessOccamTest (tests)
import qualified RainPassesTest (tests)
import qualified RainTypesTest (vioTests)
import qualified SimplifyAbbrevsTest (tests)
import qualified SimplifyTypesTest (tests)
import qualified StructureOccamTest (tests)
import qualified UsageCheckTest (tests)
import TestUtils
import Utils

data TestOption =
  QC (Either String (Maybe QuickCheckLevel))
  | OutputType Bool -- True is plain, False is erasing
  | ListTests
  | RunJust String
  | Verbose
  deriving (Eq)

type TestSet = (Test, [LabelledQuickCheckTest])

-- We run all the HUnit tests before all the QuickCheck tests.
-- We run them apart so that the output from QuickCheck doesn't get
-- confusing by being amongst the HUnit output,
-- and we run HUnit first because these are typically the more
-- interesting (and most worked on tests) so we see failures earlier.
main :: IO ()
main = do (opts, nonOpts, errs) <- getArgs >>* getOpt RequireOrder options
          when (not $ null errs) $
            err $ concat errs
          when (not $ null nonOpts) $
            err $ "Options not recognised: " ++ concat nonOpts

          qcLevel <- case findLevel opts of
                       Right level -> return level
                       Left unknown -> err $ "Unknown level: " ++ unknown

          allSets <- sequence $ tests opts
          let labelled = getLabels allSets
          selectedSets <-
            case (find (== ListTests) opts, findJust opts) of
              (Just _, _) ->
                do mapM_ putStrLn $ "Possible test names: " : map fst labelled
                   return []
              (_, Just name) ->
                return [t | (n, t) <- labelled, name `isInfixOf` n]
              _ -> return allSets

          let hunitTests = map fst selectedSets
          let qcTests = case qcLevel of
                          Just level ->
                            map (makeQCTest level . snd) selectedSets
                          Nothing -> []
          let testsToRun = hunitTests ++ qcTests

          (counts, _) <- let (h, reps) = case findType opts of
                                           Just True -> (stdout, False)
                                           _ -> (stderr, True)
                             test = TestList testsToRun
                         in runTestText (putTextToHandle h reps) test

          let numFailed = errors counts + failures counts
          when (numFailed /= 0) $
            exitWith $ ExitFailure 1
  where
    err msg = ioError (userError (msg ++ usageInfo header options))
    header = "Usage: tocktest [OPTION..]"
    options = [ Option [] ["qc", "quickcheck"]
                  (ReqArg matchLevel "LEVEL") "QuickCheck level (options: off, low, medium, high, extensive)"
              , Option [] ["plain"] (NoArg (OutputType True)) "Show the test output as plain text"
              , Option ['l'] ["list-tests"] (NoArg (ListTests)) "Show the top-level test names"
              , Option ['f'] ["filter"] (ReqArg RunJust "TESTNAME") "Run just the tests that have this in their name (use -l to list)"
              , Option ['v'] ["verbose"] (NoArg Verbose) "be more verbose (use multiple times for more detail)"
              ]
    
    findLevel :: [TestOption] -> Either String (Maybe QuickCheckLevel)
    findLevel (QC qc:_) = qc
    findLevel (_:os) = findLevel os
    findLevel [] = Right $ Just QC_Medium
    
    findType :: [TestOption] -> Maybe Bool
    findType (OutputType t:_) = Just t
    findType (_:os) = findType os
    findType [] = Nothing
    
    findJust :: [TestOption] -> Maybe String
    findJust (RunJust s:_) = Just s
    findJust (_:os) = findJust os
    findJust [] = Nothing

    matchLevel :: String -> TestOption
    matchLevel s = QC $ case s of
                     "off" -> Right Nothing
                     "low" -> Right $ Just QC_Low
                     "medium" -> Right $ Just QC_Medium
                     "high" -> Right $ Just QC_High
                     "extensive" -> Right $ Just QC_Extensive
                     unknown -> Left unknown

    makeQCTest :: QuickCheckLevel -> [LabelledQuickCheckTest] -> Test
    makeQCTest level ts =
        TestList [TestLabel s $ t level | (s, t) <- ts]

    getLabels :: [TestSet] -> [(String, TestSet)]
    getLabels tss = [getLabel n t | (n, t) <- zip [0..] tss]
      where
        getLabel :: Int -> TestSet -> (String, TestSet)
        getLabel _ t@(TestLabel label _, _) = (label, t)
        getLabel n t = ("Unknown test: " ++ show n, t)

    tests :: [TestOption] -> [IO TestSet]
    tests opts = [
              noqc AnalyseAsmTest.tests
              ,ArrayUsageCheckTest.vioqcTests v
              ,return BackendPassesTest.qcTests
              ,noqcButIO $ CheckTest.viotests v
              ,noqc CommonTest.tests
              ,return FlowGraphTest.qcTests
              ,noqc GenerateCTest.tests
              ,noqc OccamPassesTest.tests
              ,noqcButIO $ OccamTypesTest.vioTests v
              ,noqc ParseRainTest.tests
              ,noqc PassTest.tests
              ,noqc PreprocessOccamTest.tests
              ,noqc RainPassesTest.tests
              ,noqcButIO $ RainTypesTest.vioTests v
              ,noqc SimplifyAbbrevsTest.tests
              ,noqc SimplifyTypesTest.tests
              ,noqc StructureOccamTest.tests
              ,noqc UsageCheckTest.tests
            ]
      where
        v = length $ filter (== Verbose) opts

    noqc :: Test -> IO (Test, [LabelledQuickCheckTest])
    noqc t = return (t,[])

    noqcButIO :: IO Test -> IO (Test, [LabelledQuickCheckTest])
    noqcButIO t = t >>* \x -> (x,[])
