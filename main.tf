data "aws_route53_zone" "zone" {
    name  = "${local.zone_domain_name}."
}

locals {
    www_domain      = "www.${var.domain}"
    all_domains      = var.www_is_main ? [
      local.www_domain,
      var.domain
    ] : [
      var.domain,
      local.www_domain
    ]

    primary_domain   = local.all_domains[0]
    redirect_domain  = local.all_domains[1]

    domain_parts = split(".", var.domain)
    domain_length = length(local.domain_parts)
    zone_domain_name = join(".", slice(local.domain_parts, local.domain_length - 2, local.domain_length))

    endpoints = [aws_s3_bucket.main.website_endpoint, aws_s3_bucket.redirect.website_endpoint]
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.main.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:UserAgent"

      values = [var.secret]
    }
  }
}

data "aws_iam_policy_document" "deploy_policy" {
    template = file("${path.module}/policies/deploy-policy.json")

    vars = {
      bucket_arn = aws_s3_bucket.main.arn
    }

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
        "cloudfront:CreateInvalidation"
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
      index_document = "index.html"
      error_document = "404.html"
    }

    tags = var.tags
}

resource "aws_s3_bucket" "redirect" {
    bucket = local.redirect_domain

    website {
      redirect_all_requests_to = aws_s3_bucket.main.id
    }

    tags = var.tags
}

resource "aws_acm_certificate" "cert" {
    domain_name               = local.primary_domain
    subject_alternative_names = [local.redirect_domain]
    validation_method         = "DNS"
    tags                      = var.tags
}

resource "aws_route53_record" "cert" {
    count   = length(local.all_domains)
    name    = tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_name
    type    = tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_type
    records = [tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_value]
    zone_id = data.aws_route53_zone.zone.zone_id
    ttl     = 300
}

resource "aws_acm_certificate_validation" "cert" {
    certificate_arn         = aws_acm_certificate.cert.arn
    validation_record_fqdns = tolist(aws_route53_record.cert.*.fqdn)

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
      domain_name = local.endpoints[count.index]
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
      acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = lookup(var.cdn_settings, "minimum_protocol_version", "TLSv1_2016")
    }

    default_cache_behavior {
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
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
}

resource "aws_route53_record" "A" {
    count   = length(local.all_domains)
    zone_id = data.aws_route53_zone.zone.zone_id
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
    zone_id = data.aws_route53_zone.zone.zone_id
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
