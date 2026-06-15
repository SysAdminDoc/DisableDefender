@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingWMICmdlet'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseSingularNouns'
        'PSReviewUnusedParameter'
        'PSUseBOMForUnicodeEncodedFile'
        'PSAvoidOverwritingBuiltInCmdlets'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
