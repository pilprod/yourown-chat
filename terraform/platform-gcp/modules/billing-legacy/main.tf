resource "google_project_service" "bigquery" {
  project = var.project_id
  service = "bigquery.googleapis.com"

  disable_on_destroy = false
}

resource "google_bigquery_dataset" "this" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.location

  friendly_name = "Legacy Cloud Billing export"
  description   = "Detailed usage cost history from the former billing account."

  delete_contents_on_destroy = false
  max_time_travel_hours      = 168
  labels                     = var.labels

  depends_on = [google_project_service.bigquery]
}

resource "google_bigquery_dataset_iam_member" "mcp_reader" {
  project    = google_bigquery_dataset.this.project
  dataset_id = google_bigquery_dataset.this.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = var.reader_member
}
