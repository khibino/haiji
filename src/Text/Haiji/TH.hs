{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
module Text.Haiji.TH ( haiji, haijiFile, key ) where

import Language.Haskell.TH
import Language.Haskell.TH.Quote
import Language.Haskell.TH.Syntax
import Data.Attoparsec.Text
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.IO as LT
import Text.Haiji.Parse
import Text.Haiji.Types

haiji :: QuasiQuoter
haiji = QuasiQuoter { quoteExp = haijiExp
                    , quotePat = undefined
                    , quoteType = undefined
                    , quoteDec = undefined
                    }

haijiFile :: Quasi q => FilePath -> q Exp
haijiFile file = runQ (runIO $ LT.readFile file) >>= haijiExp . LT.unpack . deleteLastOneLF where
  deleteLastOneLF xs
    | "%}\n" `LT.isSuffixOf` xs     = LT.init xs
    | "\n\n" `LT.isSuffixOf` xs     = LT.init xs
    | not ("\n" `LT.isSuffixOf` xs) = xs `LT.append` "\n"
    | otherwise                     = xs

haijiImportFile :: Quasi q => FilePath -> q Exp
haijiImportFile file = runQ (runIO $ LT.readFile file) >>= haijiExp . LT.unpack . deleteLastOneLF where
  deleteLastOneLF xs
    | LT.null xs         = xs
    | LT.last xs == '\n' = LT.init xs
    | otherwise          = xs

haijiExp :: Quasi q => String -> q Exp
haijiExp = either error haijiASTs . parseOnly parser . T.pack

key :: QuasiQuoter
key = QuasiQuoter { quoteExp = \k -> [e| \v -> singleton v (Key :: Key $(litT . strTyLit $ k)) |]
                  , quotePat = undefined
                  , quoteType = undefined
                  , quoteDec = undefined
                  }

haijiASTs :: Quasi q => [AST] -> q Exp
haijiASTs asts = runQ $ do
  esc <- newName "esc"
  dict <- newName "dict"
  [e| \ $(varP esc) $(varP dict) -> LT.concat $(listE $ map (haijiAST esc dict) asts) |]

haijiAST :: Quasi q => Name -> Name -> AST -> q Exp
haijiAST esc dict (Literal l) =
    runQ [e| (\_ _ -> s) $(varE esc) $(varE dict) |] where s = T.unpack l
haijiAST esc dict (Deref x) =
    runQ [e| $(varE esc) $ toLT $ $(deref dict x) |]
haijiAST esc dict (Condition p ts (Just fs)) =
    runQ [e| (if $(deref dict p) then $(haijiASTs ts) else $(haijiASTs fs)) $(varE esc) $(varE dict) |]
haijiAST esc dict (Condition p ts Nothing) =
    runQ [e| (if $(deref dict p) then $(haijiASTs ts) else (\_ _ -> "")) $(varE esc) $(varE dict) |]
haijiAST esc dict (Foreach k xs loopBody elseBody) =
    runQ [e| let dicts = $(deref dict xs)
                 len = length dicts
             in if 0 < len
                then LT.concat
                     $ map (\(ix, x) -> $(haijiASTs loopBody)
                                        $(varE esc)
                                        ($(varE dict) `merge`
                                         singleton x (Key :: Key $(litT . strTyLit $ show k)) `merge`
                                         singleton (loopVariables len ix) (Key :: Key "loop")))
                     $ zip [0..] dicts
                else $(maybe [e| (\_ _ -> "") |] haijiASTs elseBody) $(varE esc) $(varE dict)
           |]
haijiAST esc dict (Include file) =
    runQ [e| $(haijiImportFile file) $(varE esc) $(varE dict) |]
haijiAST esc dict (Raw raw) =
    runQ [e| (\_ _ -> raw) $(varE esc) $(varE dict) |]

loopVariables :: Int -> Int -> TLDict '["first" :-> Bool, "index" :-> Int, "index0" :-> Int, "last" :-> Bool, "length" :-> Int, "revindex" :-> Int, "revindex0" :-> Int]
loopVariables len ix =
  Ext (Value (ix == 0)       :: "first"     :-> Bool) $
  Ext (Value (ix + 1)        :: "index"     :-> Int ) $
  Ext (Value ix              :: "index0"    :-> Int ) $
  Ext (Value (ix == len - 1) :: "last"      :-> Bool) $
  Ext (Value len             :: "length"    :-> Int ) $
  Ext (Value (len - ix)      :: "revindex"  :-> Int ) $
  Ext (Value (len - ix - 1)  :: "revindex0" :-> Int ) $
  Empty

class ToLT a where toLT :: a -> LT.Text
instance ToLT String  where toLT = LT.pack
instance ToLT T.Text  where toLT = LT.fromStrict
instance ToLT LT.Text where toLT = id
instance ToLT Int     where toLT = toLT . show
instance ToLT Integer where toLT = toLT . show

deref :: Quasi q => Name -> Variable -> q Exp
deref dict (Simple v) =
    runQ [e| retrieve $(varE dict) (Key :: Key $(litT . strTyLit $ show v)) |]
deref dict (Attribute v f) =
    runQ [e| retrieve $(deref dict v) (Key :: Key $(litT . strTyLit $ show f)) |]
deref dict (At v ix) =
    runQ [e| $(deref dict v) !! ix |]
