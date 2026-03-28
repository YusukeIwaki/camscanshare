package io.github.yusukeiwaki.camscanshare.di

import android.content.Context
import androidx.room.Room
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.github.yusukeiwaki.camscanshare.data.db.AppDatabase
import io.github.yusukeiwaki.camscanshare.data.db.DocumentDao
import io.github.yusukeiwaki.camscanshare.data.db.PageDao
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase =
        Room.databaseBuilder(context, AppDatabase::class.java, "camscanshare.db")
            .build()

    @Provides
    fun provideDocumentDao(db: AppDatabase): DocumentDao = db.documentDao()

    @Provides
    fun providePageDao(db: AppDatabase): PageDao = db.pageDao()
}
