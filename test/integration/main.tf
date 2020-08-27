provider "aws" {
    region = "us-east-1"
}

module "s3-static-site" {
    source          = "../.."
    
    secret          = "ghhyryr678rhbjoh"
    domain = "example.davidvargas.me"
}
