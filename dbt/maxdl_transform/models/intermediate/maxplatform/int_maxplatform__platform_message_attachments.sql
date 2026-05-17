-- 자동생성: maxplatform.platform_message_attachments Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__platform_message_attachments')) }}
from {{ ref('stg_maxplatform__platform_message_attachments') }}
