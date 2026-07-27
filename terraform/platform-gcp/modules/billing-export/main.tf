resource "google_project_iam_member" "dataset_creator" {
  project = var.project_id
  role    = "roles/bigquery.user"
  member  = var.manager_member
}

resource "google_bigquery_dataset" "this" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.location

  friendly_name = "Cloud Billing export"
  description   = "Detailed Cloud Billing usage and resource cost export."

  delete_contents_on_destroy = false
  max_time_travel_hours      = 168
  labels                     = var.labels

  depends_on = [google_project_iam_member.dataset_creator]
}

resource "google_bigquery_dataset_iam_member" "reader" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.this.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = var.reader_member
}
