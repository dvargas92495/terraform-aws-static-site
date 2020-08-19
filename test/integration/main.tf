provider "template" {}

provider "aws" {
    access_key = "my-access-key"
    secret_key = "my-secret-key"
    region = "us-east-1"
}

module "s3-static-site" {
    source          = "../.."
    countries       = ["RU", "CN"]
    enable_iam_user = false
    secret          = "ghhyryr678rhbjoh"
    www_is_main     = true

    domains = [
        "immel.co.uk",
        "immel.io"
    ]

    cdn_settings = {
        price_class              = "PriceClass_100"
        restriction_type         = "blacklist"
        minimum_protocol_version = "TLSv1.2_2018"
    }
}
