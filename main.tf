// CloudFront certificates have to be requested in us-east-1
provider "aws" {
  alias = "us-east-1"
}

locals {
    www_domain      = "www.${var.domain}"
    all_redirects   = flatten([
      for r in var.redirects: [r, "www.${r}"]
    ]) 
    all_domains      = concat(var.www_is_main ? [
      local.www_domain,
      var.domain
    ] : [
      var.domain,
      local.www_domain
    ], local.all_redirects)

    primary_domain    = local.all_domains[0]
    redirect_domains  = slice(local.all_domains, 1, length(local.all_domains))
    zone_domain_names = {
      for d in local.all_domains: d => join(".", slice(split(".", d), length(split(".", d)) - 2, length(split(".", d))))
    }
    validations = tolist(aws_acm_certificate.cert.domain_validation_options)
}

data "aws_route53_zone" "zone" {
    for_each = toset(values(local.zone_domain_names))
    name     = "${each.value}."
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${local.primary_domain}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:UserAgent"

      values = [var.secret]
    }

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

data "aws_iam_policy_document" "deploy_policy" {
    statement {
      actions = [
        "s3:ListBucket"
      ]

      resources = [
        aws_s3_bucket.main.arn
      ]
    }

    statement {
      actions = [
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:PutObjectAcl"
      ]

      resources = [
        "${aws_s3_bucket.main.arn}/*"
      ]
    }

    statement {
      actions = [
        "cloudfront:ListDistributions",
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation"
      ]

      resources = [
        "*"
      ]
    }
}

resource "aws_s3_bucket" "main" {
    bucket = local.primary_domain
    policy = data.aws_iam_policy_document.bucket_policy.json

    website {
      index_document = var.index
      error_document = var.error_document
    }
    force_destroy = true 

    cors_rule {
      allowed_headers = [
        "*",
      ]
      allowed_methods = [
        "GET",
      ]
      allowed_origins = var.allowed_origins
      expose_headers  = []
    }

    tags = var.tags
}

resource "aws_s3_bucket" "redirect" {
    for_each = toset(local.redirect_domains)
    bucket = each.value

    website {
      redirect_all_requests_to = aws_s3_bucket.main.id
    }
    force_destroy = true 

    tags = var.tags
}

resource "aws_acm_certificate" "cert" {
    domain_name               = local.primary_domain
    subject_alternative_names = local.redirect_domains
    validation_method         = "DNS"
    tags                      = var.tags
    provider                  = aws.us-east-1
    
    lifecycle {
      create_before_destroy = true
    }
}

resource "aws_route53_record" "cert" {
    count   = length(local.validations)
    name    = local.validations[count.index].resource_record_name
    type    = local.validations[count.index].resource_record_type
    records = [local.validations[count.index].resource_record_value]
    zone_id = data.aws_route53_zone.zone[local.zone_domain_names[local.validations[count.index].domain_name]].zone_id
    ttl     = 300
}

resource "aws_acm_certificate_validation" "cert" {
    certificate_arn         = aws_acm_certificate.cert.arn
    validation_record_fqdns = tolist(aws_route53_record.cert.*.fqdn)
    provider                = aws.us-east-1

    timeouts {
      create = "2h"
    }
}

resource "aws_cloudfront_distribution" "cdn" {
    count           = length(local.all_domains)
    aliases         = [local.all_domains[count.index]]
    comment         = "CloudFront CDN for ${local.all_domains[count.index]}"
    enabled         = true
    is_ipv6_enabled = true
    price_class     = lookup(var.cdn_settings, "price_class", "PriceClass_All")
    tags            = var.tags

    origin {
      domain_name = count.index == 0 ? aws_s3_bucket.main.website_endpoint : aws_s3_bucket.redirect[local.redirect_domains[count.index - 1]].website_endpoint
      origin_id   = format("S3-%s", local.all_domains[count.index])

      custom_origin_config {
        origin_protocol_policy = "http-only"
        http_port              = "80"
        https_port             = "443"
        origin_ssl_protocols = ["TLSv1", "TLSv1.2"]
      }

      custom_header {
        name  = "User-Agent"
        value = var.secret
      }
    }

    restrictions {
      geo_restriction {
        restriction_type = lookup(var.cdn_settings, "restriction_type", "none")
        locations        = var.countries
      }
    }

    viewer_certificate {
      acm_certificate_arn      = aws_acm_certificate.cert.arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = lookup(var.cdn_settings, "minimum_protocol_version", "TLSv1_2016")
    }

    default_cache_behavior {
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD", "OPTIONS"]
      target_origin_id       = format("S3-%s", local.all_domains[count.index])
      compress               = "true"
      viewer_protocol_policy = "redirect-to-https"
      min_ttl                = lookup(var.cdn_settings, "min_ttl", "0")
      default_ttl            = lookup(var.cdn_settings, "default_ttl", "86400")
      max_ttl                = lookup(var.cdn_settings, "max_ttl", "31536000")

      forwarded_values {
        query_string = false

        cookies {
          forward = "none"
        }
      }
    }

    custom_error_response {
      error_code = 404
      response_code = 200
      response_page_path = "/${var.error_document}"
    }

    custom_error_response {
      error_code = 403
      response_code = 200
      response_page_path = "/${var.index}"
    }

    depends_on = [
      aws_acm_certificate_validation.cert
    ]
}

resource "aws_route53_record" "A" {
    count   = length(local.all_domains)
    zone_id = data.aws_route53_zone.zone[local.zone_domain_names[local.all_domains[count.index]]].zone_id
    name    = local.all_domains[count.index]
    type    = "A"

    alias {
      name                   = element(aws_cloudfront_distribution.cdn.*.domain_name, count.index)
      zone_id                = element(aws_cloudfront_distribution.cdn.*.hosted_zone_id, count.index)
      evaluate_target_health = false
  }
}

resource "aws_route53_record" "AAAA" {
    count   = length(local.all_domains)
    zone_id = data.aws_route53_zone.zone[local.zone_domain_names[local.all_domains[count.index]]].zone_id
    name    = local.all_domains[count.index]
    type    = "AAAA"

    alias {
      name                   = element(aws_cloudfront_distribution.cdn.*.domain_name, count.index)
      zone_id                = element(aws_cloudfront_distribution.cdn.*.hosted_zone_id, count.index)
      evaluate_target_health = false
  }
}

resource "aws_iam_user" "deploy" {
    count = var.enable_iam_user ? 1 : 0
    name  = "${local.primary_domain}-deploy"
    path  = "/"
}

resource "aws_iam_access_key" "deploy" {
    count = var.enable_iam_user ? 1 : 0
    user  = aws_iam_user.deploy[0].name
}

resource "aws_iam_user_policy" "deploy" {
    count  = var.enable_iam_user ? 1 : 0
    name   = "deploy"
    user   = aws_iam_user.deploy[0].name
    policy = data.aws_iam_policy_document.deploy_policy.json
}
