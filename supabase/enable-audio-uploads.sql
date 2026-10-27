-- Allow common audio uploads in the private submissions bucket.
-- This adds audio formats without removing the bucket's existing MIME types.
UPDATE storage.buckets AS b
SET allowed_mime_types = ARRAY(
  SELECT DISTINCT mime_type
  FROM unnest(
    COALESCE(b.allowed_mime_types, ARRAY[]::text[])
    || ARRAY[
      'audio/mpeg',
      'audio/mp4',
      'audio/x-m4a',
      'audio/aac',
      'audio/wav',
      'audio/x-wav',
      'audio/ogg',
      'audio/webm',
      'audio/opus',
      'audio/3gpp',
      'audio/amr'
    ]::text[]
  ) AS types(mime_type)
  ORDER BY mime_type
)
WHERE b.id = 'submissions';
