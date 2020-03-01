import Hasura.GraphQL.Transport.HTTP.Protocol

x = GQLReq{_grOperationName = Nothing,
       _grQuery =
         GQLExecDoc{unGQLExecDoc =
                      [ExecutableDefinitionOperation
                         (OperationDefinitionTyped
                            (TypedOperationDefinition{_todType = OperationTypeQuery,
                                                      _todName = Nothing,
                                                      _todVariableDefinitions =
                                                        [VariableDefinition{_vdVariable =
                                                                              Variable{unVariable = Name {unName = "a"}},
                                                                            _vdType =
                                                                              TypeNamed
                                                                                (Nullability{unNullability = False})
                                                                                (NamedType{unNamedType = Name{unName = "Int"}}),
                                                                            _vdDefaultValue = Just (VCInt 1)}],
                                                      _todDirectives = [],
                                                      _todSelectionSet =
                                                        [SelectionField
                                                           (Field{_fAlias = Nothing,
                                                                  _fName = Name{unName = "author"},
                                                                  _fArguments =
                                                                    [Argument{_aName = Name{unName = "where"},
                                                                              _aValue =
                                                                                VObject
                                                                                  (ObjectValueG{unObjectValue
                                                                                                  =
                                                                                                  [ObjectFieldG{_ofName = Name{unName = "id"},
                                                                                                                _ofValue
                                                                                                                  =
                                                                                                                  VObject
                                                                                                                    (ObjectValueG{unObjectValue
                                                                                                                                    =
                                                                                                                                    [ObjectFieldG{_ofName = Name{unName = "_eq"},
                                                                                                                                                  _ofValue
                                                                                                                                                    =
                                                                                                                                                    VVariable
                                                                                                                                                      (Variable{unVariable = Name{unName = "a"}})}]})}]})}],
                                                                  _fDirectives = [],
                                                                  _fSelectionSet =
                                                                    [SelectionField
                                                                       (Field{_fAlias = Nothing,
                                                                              _fName = Name{unName = "name"},
                                                                              _fArguments = [],
                                                                              _fDirectives = [],
                                                                              _fSelectionSet =
                                                                                []})]})]}))]},
       _grVariables = Just (fromList [])}
