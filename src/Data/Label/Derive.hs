{-
Copyright (c) Erik Hesselink & Sebastiaan Visser 2008

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the author nor the names of his contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
-}
{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE
    TemplateHaskell
  , OverloadedStrings
  , FlexibleContexts
  , FlexibleInstances
  , TypeOperators
  #-}
module Data.Label.Derive
( mkLabels
, mkLabel
, mkLabelsWith
, mkLabelsMono
, mkLabelsNoTypes
) where

import Control.Arrow
import Control.Category
import Control.Monad
import Data.Char
import Data.Function (on)
import Data.Label.Abstract
import Data.Label.Pure ((:->))
import Data.Label.Maybe ((:~>))
import Data.List
import Data.Ord
import Data.String
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Prelude hiding ((.), id)

-- Throw a fclabels specific error.

fclError :: String -> a
fclError err = error ("Data.Label.Derive: " ++ err)

-- | Derive lenses including type signatures for all the record selectors for a
-- collection of datatypes. The types will be polymorphic and can be used in an
-- arbitrary context.

mkLabels :: [Name] -> Q [Dec]
mkLabels = mkLabelsWith defaultMakeLabel

-- | Derive lenses including type signatures for all the record selectors in a
-- single datatype. The types will be polymorphic and can be used in an
-- arbitrary context.

mkLabel :: Name -> Q [Dec]
mkLabel = mkLabels . return

-- | Generate the label name from the record field name.
-- For instance, @drop 1 . dropWhile (/='_')@ creates a label @val@ from a
-- record @Rec { rec_val :: X }@.

mkLabelsWith :: (String -> String) -> [Name] -> Q [Dec]
mkLabelsWith makeLabel = liftM concat . mapM (derive1 makeLabel True False)

-- | Derive lenses including type signatures for all the record selectors in a
-- datatype. The signatures will be concrete and can only be used in the
-- appropriate context.

mkLabelsMono :: [Name] -> Q [Dec]
mkLabelsMono = liftM concat . mapM (derive1 defaultMakeLabel True True)

-- | Derive lenses without type signatures for all the record selectors in a
-- datatype.

mkLabelsNoTypes :: [Name] -> Q [Dec]
mkLabelsNoTypes = liftM concat . mapM (derive1 defaultMakeLabel False False)

-- Helpers to generate all labels for one datatype.

derive1 :: (String -> String) -> Bool -> Bool -> Name -> Q [Dec]
derive1 makeLabel signatures concrete datatype =
 do i <- reify datatype
    let -- Only process data and newtype declarations, filter out all
        -- constructors and the type variables.
        (tyname, cons, vars) =
          case i of
            TyConI (DataD    _ n vs cs _) -> (n, cs,  vs)
            TyConI (NewtypeD _ n vs c  _) -> (n, [c], vs)
            _                             -> fclError "Can only derive labels for datatypes and newtypes."

        -- We are only interested in lenses of record constructors.
        recordOnly = groupByCtor [ (f, n) | RecC n fs <- cons, f <- fs ]

    concat `liftM`
        mapM (derive makeLabel signatures concrete tyname vars (length cons))
            recordOnly

    where groupByCtor = map (\xs -> (fst (head xs), map snd xs))
                      . groupBy ((==) `on` (fst3 . fst))
                      . sortBy (comparing (fst3 . fst))
                      where fst3 (a, _, _) = a

-- Generate the code for the labels.

-- | Generate a name for the label. If the original selector starts with an
-- underscore, remove it and make the next character lowercase. Otherwise,
-- add 'l', and make the next character uppercase.
defaultMakeLabel :: String -> String
defaultMakeLabel field =
  case field of
    '_' : c : rest -> toLower c : rest
    f : rest       -> 'l' : toUpper f : rest
    n              -> fclError ("Cannot derive label for record selector with name: " ++ n)

derive :: (String -> String)
       -> Bool -> Bool -> Name -> [TyVarBndr] -> Int
       -> (VarStrictType, [Name]) -> Q [Dec]
derive makeLabel signatures concrete tyname vars total ((field, _, fieldtyp), ctors) =
  do (sign, body) <-
       if length ctors == total
       then function derivePureLabel
       else function deriveMaybeLabel

     return $
       if signatures
       then [sign, inline, body]
       else [inline, body]

  where

    -- Generate an inline declaration for the label.
    inline = PragmaD (InlineP labelName (InlineSpec True True (Just (True, 0))))
    labelName = mkName (makeLabel (nameBase field))

    -- Build a single record label definition for labels that might fail.
    deriveMaybeLabel = (if concrete then mono else poly, body)
      where
        mono = forallT prettyVars (return []) [t| $(inputType) :~> $(return prettyFieldtyp) |]
        poly = forallT forallVars (return [])
          [t| (ArrowChoice $(arrow), ArrowZero $(arrow))
              => Lens $(arrow) $(inputType) $(return prettyFieldtyp) |]
        body = [| lens (fromRight . $(getter)) (fromRight . $(setter)) |]
          where
            getter    = [| arr (\    p  -> $(caseE [|p|] (cases (bodyG [|p|]      ) ++ wild))) |]
            setter    = [| arr (\(v, p) -> $(caseE [|p|] (cases (bodyS [|p|] [|v|]) ++ wild))) |]
            cases b   = map (\ctor -> match (recP ctor []) (normalB b) []) ctors
            wild      = [match wildP (normalB [| Left () |]) []]
            bodyS p v = [| Right $( record p field v ) |]
            bodyG p   = [| Right $( varE field `appE` p ) |]

    -- Build a single record label definition for labels that cannot fail.
    derivePureLabel = (if concrete then mono else poly, body)
      where
        mono = forallT prettyVars (return []) [t| $(inputType) :-> $(return prettyFieldtyp) |]
        poly = forallT forallVars (return [])
          [t| Arrow $(arrow) => Lens $(arrow) $(inputType) $(return prettyFieldtyp) |]
        body = [| lens $(getter) $(setter) |]
          where
            getter = [| arr $(varE field) |]
            setter = [| arr (\(v, p) -> $(record [| p |] field [| v |])) |]

    -- Compute the type (including type variables of the record datatype.
    inputType = return $ foldr (flip AppT) (ConT tyname) (map tvToVarT (reverse prettyVars))

    -- Convert a type variable binder to a regular type variable.
    tvToVarT (PlainTV tv) = VarT tv
    tvToVarT _            = fclError "No support for special-kinded type variables."

    -- Prettify type variables.
    arrow          = varT (mkName "~>")
    prettyVars     = map prettyTyVar vars
    forallVars     = PlainTV (mkName "~>") : prettyVars
    prettyFieldtyp = prettyType fieldtyp

    -- Q style record updating.
    record rec fld val = val >>= \v -> recUpdE rec [return (fld, v)]

    -- Build a function declaration with both a type signature and body.
    function (s, b) = liftM2 (,) 
        (sigD labelName s)
        (funD labelName [ clause [] (normalB b) [] ])

fromRight :: (ArrowChoice a, ArrowZero a) => a (Either b d) d
fromRight = zeroArrow ||| returnA

-------------------------------------------------------------------------------

-- Helper functions to prettify type variables.

prettyName :: Name -> Name
prettyName tv = mkName (takeWhile (/='_') (show tv))

prettyTyVar :: TyVarBndr -> TyVarBndr
prettyTyVar (PlainTV  tv   ) = PlainTV (prettyName tv)
prettyTyVar (KindedTV tv ki) = KindedTV (prettyName tv) ki

prettyType :: Type -> Type
prettyType (ForallT xs cx ty) = ForallT (map prettyTyVar xs) (map prettyPred cx) (prettyType ty)
prettyType (VarT nm         ) = VarT (prettyName nm)
prettyType (AppT ty tx      ) = AppT (prettyType ty) (prettyType tx)
prettyType (SigT ty ki      ) = SigT (prettyType ty) ki
prettyType ty                 = ty

prettyPred :: Pred -> Pred
prettyPred (ClassP nm tys) = ClassP (prettyName nm) (map prettyType tys)
prettyPred (EqualP ty tx ) = EqualP (prettyType ty) (prettyType tx)

-- IsString instances for TH types.

instance IsString Exp where
  fromString = VarE . mkName

instance IsString (Q Pat) where
  fromString = varP . mkName

instance IsString (Q Exp) where
  fromString = varE . mkName
