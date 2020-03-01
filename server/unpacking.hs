asPGColumnTypeAndValueM v :
  AnnInpVal{_aivType =
              TypeNamed (Nullability{unNullability = False})
                (NamedType{unNamedType = Name{unName = "Int"}}),
            _aivVariable = Just (Variable{unVariable = Name{unName = "a"}}),
            _aivValue = AGScalar PGInteger (Just (PGValInteger 1337))}
