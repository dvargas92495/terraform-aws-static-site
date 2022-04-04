variable "domain" {
    type        = string
    description = "Domain to be built into a static website."
}

variable "secret" {
    type        = string
    description = "A secret string between CloudFront and S3 to control access."
}

variable "redirects" {
    type        = list(string)
    description = "List of domains that redirect to the main domain"
    default     = []
}

variable "www_is_main" {
    type        = string
    description = "Controls whether the naked domain or www subdomain is the main site."
    default     = false
}

variable "enable_iam_user" {
    type        = string
    description = "Controls whether the module should create the AWS IAM deployment user."
    default     = true
}

variable "cdn_settings" {
    type        = map(string)
    description = "A map containing configurable CloudFront CDN settings."
    default     = {}
}

variable "tags" {
    type        = map(string)
    description = "A map of tags to add to all resources"
    default     = {}
}

variable "countries" {
    type        = list(string)
    description = "The ISO 3166-alpha-2 country codes of the countries to be allowed or restricted."
    default     = []
}

variable "allowed_origins" {
    type        = list(string)
    description = "Other origins allowed to access items from the bucket."
    default     = ["*"]
}

variable "index" {
    type        = string
    description = "Index page for the website"
    default     = "index.html"
}

variable "error_document" {
    type        = string
    description = "Error page for the website"
    default     = "404.html"
}

variable "origin_timeout" {
  type        = number
  description = "An optional timeout for the origin request lambda, defaulted to 10"
  default     = 10
}

variable "origin_memory_size" {
  type        = number
  description = "An optional memory size for the origin request lambda, defaulted to 256"
  default     = 256
}

data "aws_cloudfront_cache_policy" "cache_policy" {
  name = "Managed-Amplify"
}

variable "cache_policy_id" {
  type        = string
  description = "Identifier for the cache policy to use on the main CDN"
  default     = data.aws_cloudfront_cache_policy.cache_policy
}
