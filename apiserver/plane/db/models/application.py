from django.db import models
from django.conf import settings

from .base import BaseModel


class Application(BaseModel):
    slug = models.CharField(max_length=255, unique=True)
    name = models.CharField(max_length=255)
    author = models.CharField(max_length=255)
    summary = models.TextField(blank=True, null=True)
    description = models.JSONField(blank=True, null=True)
    description_html = models.TextField(blank=True, null=True)
    description_stripped = models.TextField(blank=True, null=True)
    logo_url = models.URLField(blank=True, null=True)
    cover_url = models.URLField(blank=True, null=True)
    is_verified = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    is_internal = models.BooleanField(default=True)

    class Meta:
        verbose_name = "Application"
        verbose_name_plural = "Applications"
        db_table = "applications"

    def __str__(self):
        return self.name


class WorkspaceApplication(BaseModel):
    workspace = models.ForeignKey(
        "db.Workspace",
        on_delete=models.CASCADE,
        related_name="workspace_application",
    )
    application = models.ForeignKey(
        Application,
        on_delete=models.CASCADE,
        related_name="workspace_application",
    )
    installed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="workspace_application",
    )
    webhook_url = models.URLField(blank=True, null=True)
    redirect_url = models.URLField(blank=True, null=True)
    is_alert_rule_enabled = models.BooleanField(default=False)
    ui_schema = models.JSONField(blank=True, null=True)
    authorized_origins = models.TextField(blank=True, null=True)

    class Meta:
        unique_together = ["workspace", "application"]
        verbose_name = "Workspace Application"
        verbose_name_plural = "Workspace Applications"
        db_table = "workspace_applications"
        ordering = ("-created_at",)

    def __str__(self):
        return f"{self.workspace} - {self.application}"


class WorkspaceApplicationScope(BaseModel):
    workspace_application = models.ForeignKey(
        WorkspaceApplication,
        on_delete=models.CASCADE,
        related_name="workspace_application_scope",
    )
    entity = models.CharField(
        max_length=255, choices=(("user", "User"), ("group", "Group"))
    )
    scope = models.CharField(
        max_length=255, choices=(("read", "Read"), ("write", "Write"))
    )

    class Meta:
        unique_together = ["workspace_application", "scope"]
        verbose_name = "Workspace Application Scope"
        verbose_name_plural = "Workspace Application Scopes"
        db_table = "workspace_application_scopes"
        ordering = ("-created_at",)

    def __str__(self):
        return f"{self.workspace_application} - {self.scope}"
