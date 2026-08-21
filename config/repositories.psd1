@{
    Repositories = @(
        @{
            Name             = 'ewsp-backend'
            Directory        = 'ewsp-backend'
            ExpectedIdentity = 'github.com/mohammad-hamadi/ewsp-backend'
            CloneUrl         = 'https://github.com/Mohammad-Hamadi/ewsp-backend'
            PrimaryBranch    = 'main'
            Image            = @{
                Service         = 'backend'
                RepositoryName  = 'ewsp-backend'
                EnvironmentName = 'EWSP_BACKEND_IMAGE'
                RequiredBuildFiles = @('Dockerfile', '.dockerignore')
                BuildInputs     = @()
            }
        }
        @{
            Name             = 'ewsp-dashboard'
            Directory        = 'ewsp-dashboard'
            ExpectedIdentity = 'github.com/mohammad-hamadi/ewsp-dashboard'
            CloneUrl         = 'https://github.com/Mohammad-Hamadi/ewsp-dashboard'
            PrimaryBranch    = 'main'
            Image            = @{
                Service         = 'dashboard'
                RepositoryName  = 'ewsp-dashboard'
                EnvironmentName = 'EWSP_DASHBOARD_IMAGE'
                RequiredBuildFiles = @('Dockerfile', '.dockerignore', 'nginx.conf')
                BuildInputs     = @('VITE_API_BASE_URL')
            }
        }
        @{
            Name             = 'ewsp-mobile'
            Directory        = 'ewsp-mobile'
            ExpectedIdentity = 'github.com/mohammad-hamadi/ewsp-mobile'
            CloneUrl         = 'https://github.com/Mohammad-Hamadi/ewsp-mobile.git'
            PrimaryBranch    = 'main'
        }
    )
}
