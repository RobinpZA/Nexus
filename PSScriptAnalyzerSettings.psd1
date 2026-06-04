@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
        'PSUseBOMForUnicodeEncodedFile'
    )
}
