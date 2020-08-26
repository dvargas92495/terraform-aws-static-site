provider "aws" {
    region = "us-east-1"
}

module "s3-static-site" {
    source          = "../.."
    countries       = ["RU", "CN"]
    secret          = "ghhyryr678rhbjoh"
    www_is_main     = true

    domain = "example.davidvargas.me"

    cdn_settings = {
        price_class              = "PriceClass_100"
        restriction_type         = "blacklist"
        minimum_protocol_version = "TLSv1.2_2018"
    }
}
