// CloudFront certificates have to be requested in us-east-1
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      version               = ">= 3.0.0"
      configuration_aliases = [aws.us-east-1]
    }
  }
}

data "aws_cloudfront_cache_policy" "cache_policy" {
  name = "Managed-Amplify"
}

locals {
    domain_formatted = replace(var.domain, ".", "-")
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
    cache_policy_id = length(var.cache_policy_id) > 0 ? var.cache_policy_id : data.aws_cloudfront_cache_policy.cache_policy.id
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "zone" {
    for_each = toset(values(local.zone_domain_names))
    name     = "${each.value}."
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
        "cloudfront:ListDistributions"
      ]

      resources = [
        "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution"
      ]
    }

    statement {
      actions = [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:UpdateDistribution",
        "cloudfront:GetDistribution"
      ]

      resources = [
        aws_cloudfront_distribution.cdn[0].arn
      ]
    }

    statement {
      actions = [
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:EnableReplication*"
      ]

      resources = [
        aws_lambda_function.origin_request.arn,
        aws_lambda_function.viewer_request.arn,
        "${aws_lambda_function.origin_request.arn}:*",
        "${aws_lambda_function.viewer_request.arn}:*"
      ]
    }
}

resource "aws_s3_bucket" "main" {
    bucket = local.primary_domain
    force_destroy = true

    tags = var.tags
}

resource "aws_s3_bucket_website_configuration" "main_website" {
  index_document {
    suffix = var.index
  }
  error_document {
    key = var.error_document
  }
  bucket = aws_s3_bucket.main.id
}

resource "aws_s3_bucket_cors_configuration" "main_cors" {
  bucket = aws_s3_bucket.main.id
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
}

resource "aws_s3_bucket" "redirect" {
    for_each = toset(local.redirect_domains)
    bucket = each.value
    force_destroy = true 

    tags = var.tags
}

resource "aws_s3_bucket_website_configuration" "redirect_website" {
  bucket = aws_s3_bucket.redirect.id
  redirect_all_requests_to {
    host_name = aws_s3_bucket.main.id
  }
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
    count   = length(local.all_domains)
    name    = tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_name
    type    = tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_type
    records = [tolist(aws_acm_certificate.cert.domain_validation_options)[count.index].resource_record_value]
    zone_id = data.aws_route53_zone.zone[local.zone_domain_names[local.all_domains[count.index]]].zone_id
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

data "archive_file" "viewer-request" {
  type        = "zip"
  output_path = "./viewer-request.zip"

  source {
    content   = "module.exports.handler = (e, _, c) => c(null, e.Records[0].cf.request)"
    filename  = "viewer-request.js"
  }
}

data "archive_file" "origin-request" {
  type        = "zip"
  output_path = "./origin-request.zip"

  source {
    content   = <<-EOT
      module.exports.handler = (event, _, c) => {
        const request = event.Records[0].cf.request;
        const olduri = request.uri;
        if (/\/$/.test(olduri)) {
          const newuri = olduri + "index.html";
          request.uri = encodeURI(newuri);
        } else if (!/\./.test(olduri)) {
          const newuri = olduri + ".html";
          request.uri = encodeURI(newuri);
        }
        c(null, request);
      }
    EOT
    filename  = "origin-request.js"
  }
}

data "aws_iam_policy_document" "assume_lambda_edge_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com",
        "edgelambda.amazonaws.com"
      ]
    }
  }
}

data "aws_iam_policy_document" "lambda_logs_policy_doc" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListDistributions",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "lambda:InvokeFunction",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
      "ses:sendEmail"
    ]
  }
}

resource "aws_iam_role_policy" "logs_role_policy" {
  name   = "${local.domain_formatted}-lambda-cloudfront"
  role   = aws_iam_role.cloudfront_lambda.id
  policy = data.aws_iam_policy_document.lambda_logs_policy_doc.json
}

resource "aws_iam_role" "cloudfront_lambda" {
  name = "${local.domain_formatted}-lambda-cloudfront"
  tags = var.tags
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_edge_policy.json
}

resource "aws_lambda_function" "viewer_request" {
  function_name    = "${local.domain_formatted}_viewer-request"
  role             = aws_iam_role.cloudfront_lambda.arn
  handler          = "viewer-request.handler"
  runtime          = "nodejs16.x"
  publish          = true
  tags             = var.tags
  filename         = "viewer-request.zip"
}

resource "aws_lambda_function" "origin_request" {
  function_name    = "${local.domain_formatted}_origin-request"
  role             = aws_iam_role.cloudfront_lambda.arn
  handler          = "origin-request.handler"
  runtime          = "nodejs16.x"
  publish          = true
  tags             = var.tags
  filename         = "origin-request.zip"
  timeout          = var.origin_timeout
  memory_size      = var.origin_memory_size
}

data "aws_cloudfront_origin_request_policy" "origin_policy" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_origin_access_identity" "cdn" {
  comment = "Identity for CloudFront only access"
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
      origin_id   = format("S3-%s", local.all_domains[count.index])

      // START LEGACY
      domain_name = count.index == 0 ? aws_s3_bucket.main.website_endpoint : aws_s3_bucket.redirect[local.redirect_domains[count.index - 1]].website_endpoint
      custom_origin_config {
        origin_protocol_policy = "http-only"
        http_port              = "80"
        https_port             = "443"
        origin_ssl_protocols = ["TLSv1", "TLSv1.2"]
      }
      custom_header {
        name  = "Referer"
        value = var.secret
      }

/*
      domain_name = count.index == 0 ? aws_s3_bucket.main.bucket_domain_name : aws_s3_bucket.redirect[local.redirect_domains[count.index - 1]].bucket_domain_name
      s3_origin_config {
        origin_access_identity = aws_cloudfront_origin_access_identity.cdn.cloudfront_access_identity_path
      }
*/ // END LEGACY
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
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD", "OPTIONS"]
      target_origin_id         = format("S3-%s", local.all_domains[count.index])
      compress                 = "true"
      viewer_protocol_policy   = "redirect-to-https"
      cache_policy_id          = local.cache_policy_id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.origin_policy.id

      dynamic "lambda_function_association" {
        for_each = count.index == 0 ? [{
          event_type = "viewer-request", 
          arn = aws_lambda_function.viewer_request.qualified_arn,
          include_body = false
        }, {
          event_type = "origin-request",
          arn = aws_lambda_function.origin_request.qualified_arn,
          include_body = true
        }] : []
        content {
          event_type   = lambda_function_association.value.event_type
          lambda_arn   = lambda_function_association.value.arn
          include_body = lambda_function_association.value.include_body
        }
      }
    }

    depends_on = [
      aws_acm_certificate_validation.cert
    ]
}

// START LEGACY
data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = ["${aws_s3_bucket.main.arn}/*"]

    condition {
      test     = "StringLike"
      variable = "aws:Referer"

      values = [var.secret]
    }

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

/*
data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = ["${aws_s3_bucket.main.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [
        aws_cloudfront_origin_access_identity.cdn.iam_arn
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}
*/
// END LEGACY

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
