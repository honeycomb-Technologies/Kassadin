/// Machine evaluation errors.
pub const MachineError = error{
    OutOfBudget,
    UnboundVariable,
    TypeMismatch,
    NonFunctionalApplication,
    NonConstrScrutinee,
    MissingCaseBranch,
    BuiltinError,
    BuiltinTermArgumentExpected,
    NonPolymorphicInstantiation,
    UnexpectedBuiltinTermArgument,
    OpenTermEvaluated,
    OutOfMemory,
};
