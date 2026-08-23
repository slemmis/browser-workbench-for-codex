@{
    Severity = @('Error', 'Warning')
    # These rules misclassify private helpers and script-scope limit parameters.
    # Native behavior tests cover the affected paths directly.
    ExcludeRules = @(
        'PSReviewUnusedParameter'
        'PSUseApprovedVerbs'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
