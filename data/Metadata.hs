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

-- | Metadata -- i.e. source position.
module Metadata where

{-! global : Haskell2Xml !-}

import Data.Generics (Data, Typeable)
import Data.List
import Numeric
import Text.Printf
import Text.Regex

data Meta = Meta {
    metaFile :: Maybe String,
    metaLine :: Int,
    metaColumn :: Int
  }
  deriving (Typeable, Data, Ord, Eq)

emptyMeta :: Meta
emptyMeta = Meta {
              metaFile = Nothing,
              metaLine = 0,
              metaColumn = 0
            }

instance Show Meta where
  show m =
      case metaFile m of
        Just s -> s ++ ":" ++ show (metaLine m) ++ ":" ++ show (metaColumn m)
        Nothing -> "no source position"

dropSpaces :: String -> String
dropSpaces = dropWhile (== ' ')

instance Read Meta where
  readsPrec n str
    | show emptyMeta `isPrefixOf` dropSpaces str
       = [(Meta Nothing 0 0, drop (length $ show emptyMeta) $ dropSpaces str)]
    | otherwise
       = [ (Meta (Just fn) (read l) (read n), r'') ]
       where
         (fn, ':':r) = span (/= ':') $ dropSpaces str
         (l, ':':r') = span (/= ':') r
         (n, r'') = span (`elem` ['0'..'9']) r'

-- | Encode a Meta as the prefix of a string.
packMeta :: Meta -> String -> String
packMeta m s
    = case metaFile m of
        Nothing -> s
        Just fn -> printf "//pos:%d:%d:%s//%s"
                          (metaLine m) (metaColumn m) (unslash fn) s
  where
    -- | Remove doubled slashes from a string, so we can unambiguously encode it.
    unslash :: String -> String
    unslash s = subRegex (mkRegex "//+") s "/"

-- | Extract a Meta (encoded by packMeta) from a String.
unpackMeta :: String -> (Maybe Meta, String)
unpackMeta s
    = case matchRegex metaRE s of
        Just [before, line, col, file, after] ->
          (Just $ Meta (Just file) (getInt line) (getInt col), before ++ after)
        Nothing -> (Nothing, s)
  where
    metaRE = mkRegex "^(.*)//pos:([0-9]*):([0-9]*):(.*)//(.*)$"
    getInt s = case readDec s of [(v, "")] -> v

