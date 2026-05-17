-- 자동생성: maxapex.maxapex_notice_mail_mentions Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__maxapex_notice_mail_mentions')) }}
from {{ ref('stg_maxapex__maxapex_notice_mail_mentions') }}
